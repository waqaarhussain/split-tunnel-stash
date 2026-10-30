import asyncio
import base64
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import ssl
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import dns.message
import dns.rrset
import https_proxy as p
import manager as m


class DNSAndProfileTests(unittest.TestCase):
    def test_private_multicast_self_and_ipv6_destinations_rejected(self):
        for address in ('127.0.0.1', '10.0.0.1', '169.254.169.254', '100.64.0.1',
                        '224.0.0.1', '255.255.255.255', '45.88.89.23', '::1'):
            with self.assertRaises(ValueError):
                p.public_address(address, '45.88.89.23')
        self.assertEqual(p.public_address('8.8.8.8', '45.88.89.23'), '8.8.8.8')

    def test_doh_uses_private_profile_and_checks_wire_response(self):
        class Connection:
            def request(self, method, path, body, headers):
                self.query = dns.message.from_wire(body)
                self.path = path
                self.method = method
            def getresponse(self):
                answer = dns.message.make_response(self.query)
                answer.answer.append(dns.rrset.from_text('video.example.', 60, 'IN', 'A', '8.8.8.8'))
                self.answer = answer
                return self
            status = 200
            def read(self, _): return self.answer.to_wire()
            def close(self): pass
        connection = Connection()
        with patch.object(p, 'ControlDConnection', return_value=connection):
            addresses, ttl = p.doh_lookup('video.example', 'https://dns.controld.com/TEST_ID', '45.88.89.23')
        self.assertEqual(connection.path, '/TEST_ID')
        self.assertEqual(connection.method, 'POST')
        self.assertEqual(addresses, ['8.8.8.8'])
        self.assertEqual(ttl, 60)
        with self.assertRaises(ValueError):
            p.doh_lookup('video.example', 'https://other.example/id', '45.88.89.23')

    def test_stash_https_node_has_verified_tls_and_keeps_clash_wireguard(self):
        settings = {'endpoint': '45.88.89.23', 'server_public': 'PUB',
                    'mihomo_doh': 'https://dns.controld.com/TEST_ID',
                    'stash_proxy_enabled': True, 'stash_proxy_port': 9443}
        client = {'ip': '10.88.0.2', 'private': 'PRIVATE', 'token': 'A' * 43}
        stash = m.make_config(settings, client)
        node = stash['proxies'][0]
        self.assertEqual(node['type'], 'http')
        self.assertTrue(node['tls'])
        self.assertFalse(node['skip-cert-verify'])
        self.assertEqual(node['password'], client['token'])
        self.assertNotIn('private-key', node)
        self.assertEqual(stash['rules'][-1], 'MATCH,DIRECT')
        clash = m.make_mihomo_config(settings, client)
        self.assertEqual(clash['proxies'][0]['type'], 'wireguard')
        self.assertFalse(clash['proxies'][0]['remote-dns-resolve'])


class RelayTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.state = self.root / 'state'
        self.state.mkdir()
        self.token = 'A' * 43
        self.settings = {'endpoint': '45.88.89.23', 'mihomo_doh': 'https://dns.controld.com/TEST_ID'}
        (self.state / 'settings.json').write_text(json.dumps(self.settings))
        (self.state / 'clients.json').write_text(json.dumps({'Phone': {'token': self.token}}))
        self.state_patch = patch.object(p, 'STATE', self.state)
        self.state_patch.start()
        self.cert = self.root / 'cert.pem'
        self.key = self.root / 'key.pem'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
            '-keyout', str(self.key), '-out', str(self.cert), '-days', '1',
            '-subj', '/CN=target.test', '-addext', 'subjectAltName=IP:127.0.0.1,DNS:target.test'],
            check=True, capture_output=True)
        self.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.context.load_cert_chain(self.cert, self.key)
        self.relay = p.Relay()
        self.server = await asyncio.start_server(self.relay.handle, '127.0.0.1', 0, ssl=self.context, limit=16384)
        self.port = self.server.sockets[0].getsockname()[1]
        self.client_context = ssl.create_default_context(cafile=str(self.cert))

    async def asyncTearDown(self):
        self.server.close()
        await self.server.wait_closed()
        self.state_patch.stop()
        self.temp.cleanup()

    def auth(self):
        return 'Proxy-Authorization: Basic ' + base64.b64encode(('stash:' + self.token).encode()).decode() + '\r\n'

    async def request(self, request):
        reader, writer = await asyncio.open_connection('127.0.0.1', self.port, ssl=self.client_context)
        writer.write(request.encode()); await writer.drain()
        response = await asyncio.wait_for(reader.read(), 3)
        writer.close(); await writer.wait_closed()
        return response

    async def test_authentication_port_limits_and_revocation(self):
        response = await self.request('CONNECT target.test:443 HTTP/1.1\r\n\r\n')
        self.assertIn(b'407', response)
        response = await self.request('CONNECT target.test:22 HTTP/1.1\r\n' + self.auth() + '\r\n')
        self.assertIn(b'403', response)
        response = await self.request('CONNECT 127.0.0.1:443 HTTP/1.1\r\n' + self.auth() + '\r\n')
        self.assertIn(b'403', response)
        (self.state / 'clients.json').write_text('{}')
        response = await self.request('CONNECT target.test:443 HTTP/1.1\r\n' + self.auth() + '\r\n')
        self.assertIn(b'407', response)
        self.assertEqual(self.relay.active, 0)

    async def test_doh_failure_does_not_fall_back_to_system_dns(self):
        with patch.object(p, 'doh_lookup', side_effect=ValueError('blocked')), \
             patch.object(p.socket, 'getaddrinfo', side_effect=AssertionError('Unexpected system DNS')):
            response = await self.request('CONNECT target.test:443 HTTP/1.1\r\n' + self.auth() + '\r\n')
        self.assertIn(b'403', response)

    async def test_end_to_end_curl_tls_connect_and_inner_https(self):
        async def target(reader, writer):
            try:
                await reader.readuntil(b'\r\n\r\n')
                writer.write(b'HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello')
                await writer.drain()
            finally:
                writer.close()
                with contextlib.suppress(Exception): await writer.wait_closed()
        upstream = await asyncio.start_server(target, '127.0.0.1', 0, ssl=self.context)
        upstream_port = upstream.sockets[0].getsockname()[1]
        original_open = asyncio.open_connection
        async def mapped_open(host, port, **kwargs):
            self.assertEqual((host, port), ('8.8.8.8', 443))
            return await original_open('127.0.0.1', upstream_port, **kwargs)
        try:
            with patch.object(p, 'doh_lookup', return_value=(['8.8.8.8'], 60)) as lookup, \
                 patch.object(p.asyncio, 'open_connection', side_effect=mapped_open):
                process = await asyncio.create_subprocess_exec('curl', '-fsS', '--max-time', '10',
                    '--noproxy', '', '--proxy', 'https://127.0.0.1:' + str(self.port),
                    '--proxy-cacert', str(self.cert), '--cacert', str(self.cert),
                    '--proxy-user', 'stash:' + self.token, 'https://target.test/test',
                    stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
                stdout, stderr = await process.communicate()
                self.assertEqual(process.returncode, 0, stderr.decode())
                self.assertEqual(stdout, b'hello')
                lookup.assert_called_once_with('target.test', self.settings['mihomo_doh'], self.settings['endpoint'])
        finally:
            upstream.close(); await upstream.wait_closed()


if __name__ == '__main__': unittest.main()
