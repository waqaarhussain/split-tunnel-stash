#!/usr/bin/env python3
"""Authenticated TLS CONNECT relay with explicit Control D DoH resolution."""
import asyncio
import base64
import contextlib
import hmac
import http.client
import ipaddress
import json
from pathlib import Path
import re
import socket
import ssl
import time
from urllib.parse import urlsplit

import dns.exception
import dns.message
import dns.rcode
import dns.rdatatype

STATE = Path('/var/lib/stash-split-tunnel')
CERT_ROOT = Path('/var/lib/stash-https/data/caddy/certificates')
MAX_CONNECTIONS = 128
MAX_PER_CLIENT = 16


def load(name):
    return json.loads((STATE / name).read_text())


def public_address(value, endpoint):
    address = ipaddress.ip_address(value)
    # The relay is IPv4-only, matching the existing client profile.
    if (address.version != 4 or not address.is_global or address.is_multicast
            or address.is_reserved or str(address) == endpoint):
        raise ValueError('Destination is not an allowed public IPv4 address')
    return str(address)


def authenticate(headers):
    value = headers.get('proxy-authorization', '')
    try:
        scheme, encoded = value.split(' ', 1)
        if scheme.lower() != 'basic':
            return None
        username, token = base64.b64decode(encoded, validate=True).decode('ascii').split(':', 1)
        if username != 'stash' or not re.fullmatch(r'[A-Za-z0-9_-]{43}', token):
            return None
        for client in load('clients.json').values():
            if hmac.compare_digest(client['token'], token):
                return token
    except (ValueError, UnicodeError):
        pass
    return None


class ControlDConnection(http.client.HTTPSConnection):
    """Connect to Control D's published address with normal hostname verification."""
    def __init__(self):
        self.tls_context = ssl.create_default_context()
        super().__init__('dns.controld.com', timeout=10, context=self.tls_context)

    def connect(self):
        raw = socket.create_connection(('76.76.2.22', 443), self.timeout)
        try:
            self.sock = self.tls_context.wrap_socket(raw, server_hostname='dns.controld.com')
        except BaseException:
            raw.close()
            raise


def doh_lookup(host, upstream, endpoint):
    parsed = urlsplit(upstream)
    if not re.fullmatch(r'https://dns\.controld\.com/[A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)?', upstream):
        raise ValueError('Explicit Control D DoH is required')
    query = dns.message.make_query(host, dns.rdatatype.A)
    connection = ControlDConnection()
    try:
        connection.request('POST', parsed.path, body=query.to_wire(), headers={
            'Content-Type': 'application/dns-message', 'Accept': 'application/dns-message'})
        response = connection.getresponse()
        if response.status != 200:
            raise ValueError('DoH query failed')
        body = response.read(65536)
        answer = dns.message.from_wire(body)
        if not query.is_response(answer) or answer.rcode() != dns.rcode.NOERROR:
            raise ValueError('Invalid DNS answer')
        addresses, ttls = [], []
        for rrset in answer.answer:
            if rrset.rdtype == dns.rdatatype.A:
                for item in rrset:
                    addresses.append(public_address(item.address, endpoint))
                ttls.append(rrset.ttl)
        if not addresses:
            raise ValueError('No public IPv4 answer')
        return list(dict.fromkeys(addresses)), min(ttls + [300])
    finally:
        connection.close()


def certificate_files(endpoint):
    candidates = sorted(CERT_ROOT.rglob(endpoint + '.crt'))
    for certificate in candidates:
        key = certificate.with_suffix('.key')
        if key.is_file():
            return certificate, key
    raise ValueError('Trusted endpoint certificate not found')


class Relay:
    def __init__(self):
        self.active = 0
        self.per_client = {}
        self.cache = {}

    async def resolve(self, host, settings):
        endpoint = settings['endpoint']
        try:
            return [public_address(host, endpoint)]
        except ValueError:
            # Never resolve a forbidden literal IP as a hostname.
            try:
                ipaddress.ip_address(host)
            except ValueError:
                pass
            else:
                raise
        host = host.rstrip('.').lower()
        if len(host) > 253 or not re.fullmatch(r'[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?', host):
            raise ValueError('Invalid hostname')
        upstream = settings.get('mihomo_doh', '')
        key = (upstream, host, endpoint)
        cached = self.cache.get(key)
        if cached and cached[0] > time.monotonic():
            return cached[1]
        addresses, ttl = await asyncio.to_thread(doh_lookup, host, upstream, endpoint)
        if len(self.cache) >= 2048:
            self.cache.clear()
        self.cache[key] = (time.monotonic() + max(0, ttl), addresses)
        return addresses

    async def reply(self, writer, code):
        phrases = {200: 'OK', 400: 'Bad Request', 403: 'Forbidden',
                   405: 'Method Not Allowed', 407: 'Proxy Authentication Required',
                   502: 'Bad Gateway', 503: 'Service Unavailable'}
        auth = 'Proxy-Authenticate: Basic realm="Stash"\r\n' if code == 407 else ''
        writer.write(('HTTP/1.1 %d %s\r\n%sContent-Length: 0\r\nConnection: close\r\n\r\n'
                      % (code, phrases[code], auth)).encode('ascii'))
        await writer.drain()

    async def copy(self, reader, writer):
        while True:
            chunk = await asyncio.wait_for(reader.read(65536), 120)
            if not chunk:
                return
            writer.write(chunk)
            await asyncio.wait_for(writer.drain(), 120)

    async def revoked(self, token):
        while True:
            await asyncio.sleep(10)
            if not any(hmac.compare_digest(c['token'], token) for c in load('clients.json').values()):
                return

    async def handle(self, reader, writer):
        upstream_writer = None
        counted, token_counted, token = False, False, None
        tasks = []
        connected = False
        try:
            if self.active >= MAX_CONNECTIONS:
                await self.reply(writer, 503)
                return
            self.active += 1
            counted = True
            raw = await asyncio.wait_for(reader.readuntil(b'\r\n\r\n'), 10)
            if len(raw) > 16384:
                await self.reply(writer, 400)
                return
            lines = raw.decode('ascii').split('\r\n')
            method, target, version = lines[0].split(' ')
            if version not in ('HTTP/1.0', 'HTTP/1.1'):
                await self.reply(writer, 400)
                return
            if method == 'GET' and target == '/health':
                await self.reply(writer, 200)
                return
            headers = {}
            for line in lines[1:]:
                if not line:
                    break
                key, value = line.split(':', 1)
                key = key.lower().strip()
                if key in headers:
                    raise ValueError('Duplicate header')
                headers[key] = value.strip()
            token = authenticate(headers)
            if token is None:
                await self.reply(writer, 407)
                return
            if method != 'CONNECT':
                await self.reply(writer, 405)
                return
            host, port = target.rsplit(':', 1)
            if port != '443' or host.startswith('['):
                await self.reply(writer, 403)
                return
            if self.per_client.get(token, 0) >= MAX_PER_CLIENT:
                await self.reply(writer, 503)
                return
            self.per_client[token] = self.per_client.get(token, 0) + 1
            token_counted = True
            settings = load('settings.json')
            try:
                addresses = await self.resolve(host, settings)
            except ValueError:
                await self.reply(writer, 403)
                return
            for address in addresses:
                try:
                    upstream_reader, upstream_writer = await asyncio.wait_for(
                        asyncio.open_connection(address, 443), 10)
                    break
                except (OSError, asyncio.TimeoutError):
                    pass
            if upstream_writer is None:
                await self.reply(writer, 502)
                return
            writer.write(b'HTTP/1.1 200 Connection Established\r\n\r\n')
            await writer.drain()
            connected = True
            tasks = [asyncio.create_task(self.copy(reader, upstream_writer)),
                     asyncio.create_task(self.copy(upstream_reader, writer)),
                     asyncio.create_task(self.revoked(token))]
            await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        except (OSError, ValueError, asyncio.TimeoutError, asyncio.IncompleteReadError,
                asyncio.LimitOverrunError, dns.exception.DNSException, http.client.HTTPException):
            if not connected:
                with contextlib.suppress(Exception):
                    await self.reply(writer, 502)
        finally:
            for task in tasks:
                task.cancel()
            if tasks:
                await asyncio.gather(*tasks, return_exceptions=True)
            if token_counted:
                self.per_client[token] -= 1
                if not self.per_client[token]:
                    del self.per_client[token]
            if counted:
                self.active -= 1
            for stream in (upstream_writer, writer):
                if stream:
                    stream.close()
                    with contextlib.suppress(Exception):
                        await stream.wait_closed()


async def main():
    settings = load('settings.json')
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.set_alpn_protocols(['http/1.1'])
    certificate, key = certificate_files(settings['endpoint'])
    context.load_cert_chain(certificate, key)
    stamp = (certificate.stat().st_mtime_ns, key.stat().st_mtime_ns)
    relay = Relay()
    server = await asyncio.start_server(relay.handle, '0.0.0.0',
        settings.get('stash_proxy_port', 9443), ssl=context, limit=16384,
        ssl_handshake_timeout=10, backlog=128)

    async def renew():
        nonlocal stamp
        while True:
            await asyncio.sleep(30)
            try:
                current = (certificate.stat().st_mtime_ns, key.stat().st_mtime_ns)
                if current != stamp:
                    context.load_cert_chain(certificate, key)
                    stamp = current
            except (OSError, ssl.SSLError):
                print('Certificate reload failed; retaining current TLS context.', flush=True)
    renewal = asyncio.create_task(renew())
    try:
        async with server:
            await server.serve_forever()
    finally:
        renewal.cancel()


if __name__ == '__main__':
    asyncio.run(main())
