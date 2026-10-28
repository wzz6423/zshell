"""Exercise the production event transport over real private Unix sockets.

Run: python3 mac/tests/test_automation_event_transport.py
All Swift binaries, sockets and test files are removed with TemporaryDirectory.
"""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'zshell'

HARNESS = r'''
import Darwin
import Foundation

final class State: @unchecked Sendable {
    let lock = NSLock()
    var connections: [ZshellAutomationEventConnection] = []
    func add(_ connection: ZshellAutomationEventConnection) {
        lock.lock(); defer { lock.unlock() }
        connections.append(connection)
    }
    func emit(_ count: Int, bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        for index in 1...max(1, count) {
            for connection in connections where !connection.isClosed {
                connection.send(.object([
                    "version": .number(1), "stream_id": .string("test-stream"),
                    "sequence": .number(Double(index)), "event": .string("pane.created"),
                    "data": .string(String(repeating: "x", count: bytes)),
                ]))
            }
        }
        connections.removeAll { $0.isClosed }
    }
}
@main struct Probe {
    static func main() throws {
        let path = CommandLine.arguments[2]
        if CommandLine.arguments[1] == "follow" {
            let matched = try ZshellAutomationSocketServer.followEvents(
                path: path,
                request: .init(version: 1, id: "follow", method: "events.subscribe", token: "test-token", terminalID: "terminal", params: [:]),
                timeoutMS: 400
            ) { value in
                print(String(decoding: try JSONEncoder().encode(value), as: UTF8.self))
                return value.objectValue?["event"]?.stringValue == "pane.created"
            }
            print(matched ? "matched" : "timeout")
            return
        }
        let state = State()
        let server = try ZshellAutomationSocketServer(path: path, streamHandler: { request, connection in
            guard request.token == "test-token" else {
                connection.finish(.failure(id: request.id, code: "unauthorized", message: "invalid capability"))
                return
            }
            connection.setLagFrame(.object(["event": .string("stream.lagged")]))
            connection.reply(.success(id: request.id, result: .object([
                "version": .number(1), "stream_id": .string("test-stream"),
                "sequence": .number(0), "event": .string("stream.ready"),
            ])))
            state.add(connection)
        }) { request, reply in
            if request.method == "emit" {
                state.emit(request.params["count"]?.intValue ?? 1, bytes: request.params["bytes"]?.intValue ?? 0)
            }
            reply(.success(id: request.id, result: .bool(true)))
        }
        setbuf(stdout, nil)
        print("ready")
        withExtendedLifetime(server) { RunLoop.current.run() }
    }
}
'''


class EventTransportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='zshell-events-transport-', dir='/tmp')
        cls.addClassCleanup(cls.temp.cleanup)
        cls.root = Path(cls.temp.name)
        source = cls.root / 'Probe.swift'
        source.write_text(HARNESS)
        cls.binary = cls.root / 'probe'
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(source),
                        str(SOURCE / 'ZshellAutomationProtocol.swift'), '-o', str(cls.binary)], check=True)

    def setUp(self):
        self.path = str(self.root / f'{self._testMethodName[-25:]}.sock')
        self.process = subprocess.Popen([str(self.binary), 'serve', self.path], stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, text=True)
        self.addCleanup(self.stop)
        self.assertEqual(self.process.stdout.readline().strip(), 'ready')
        self.sockets = []

    def stop(self):
        for client in self.sockets:
            client.close()
        self.process.terminate()
        self.process.communicate(timeout=5)

    def request(self, method='events.subscribe', token='test-token', **params):
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.settimeout(4)
        client.connect(self.path)
        self.sockets.append(client)
        client.sendall(json.dumps(dict(version=1, id='test', method=method, token=token,
                                       terminalID='terminal', params=params)).encode() + b'\n')
        stream = client.makefile('rb')
        self.addCleanup(stream.close)
        return client, stream

    def test_private_auth_and_incremental_delivery(self):
        self.assertEqual(os.stat(self.path).st_mode & 0o777, 0o600)
        _, rejected = self.request(token='invalid')
        self.assertEqual(json.loads(rejected.readline())['error']['code'], 'unauthorized')
        self.assertEqual(rejected.read(), b'')
        _, stream = self.request()
        self.assertEqual(json.loads(stream.readline())['result']['event'], 'stream.ready')
        _, reply = self.request('emit')
        self.assertTrue(json.loads(reply.readline())['ok'])
        self.assertEqual(json.loads(stream.readline())['event'], 'pane.created')
        _, reply = self.request('emit')
        self.assertTrue(json.loads(reply.readline())['ok'])
        self.assertEqual(json.loads(stream.readline())['event'], 'pane.created')

    def test_deadline_and_once_use_stream_client(self):
        result = subprocess.run([str(self.binary), 'follow', self.path], capture_output=True, text=True,
                                check=True, timeout=3)
        self.assertIn('stream.ready', result.stdout)
        self.assertTrue(result.stdout.strip().endswith('timeout'))
        follower = subprocess.Popen([str(self.binary), 'follow', self.path], stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, text=True)
        time.sleep(.1)
        _, reply = self.request('emit')
        self.assertTrue(json.loads(reply.readline())['ok'])
        stdout, stderr = follower.communicate(timeout=3)
        self.assertEqual(follower.returncode, 0, stderr)
        self.assertTrue(stdout.strip().endswith('matched'))

    def test_subscription_limit_and_disconnect_reclaims_slot(self):
        clients = []
        for _ in range(32):
            client, stream = self.request()
            self.assertTrue(json.loads(stream.readline())['ok'])
            clients.append((client, stream))
        _, rejected = self.request()
        self.assertEqual(json.loads(rejected.readline())['error']['code'], 'subscription_limit')
        clients[0][1].close()
        clients[0][0].close()
        time.sleep(.1)
        _, accepted = self.request()
        self.assertTrue(json.loads(accepted.readline())['ok'])

    def test_slow_client_reports_lag_and_does_not_block_rpc(self):
        client, stream = self.request()
        self.assertTrue(json.loads(stream.readline())['ok'])
        start = time.monotonic()
        _, reply = self.request('emit', count=2000, bytes=8192)
        self.assertTrue(json.loads(reply.readline())['ok'])
        self.assertLess(time.monotonic() - start, 1.5)
        frames = [json.loads(line) for line in stream]
        events = [frame['event'] for frame in frames]
        self.assertIn('stream.lagged', events)
        sequences = [frame['sequence'] for frame in frames]
        self.assertEqual(sequences, sorted(set(sequences)))
        self.assertLess(len(events), 2000)
        _, healthy = self.request('ping')
        self.assertTrue(json.loads(healthy.readline())['ok'])

    def test_idle_disconnect_does_not_accumulate_subscriptions(self):
        for _ in range(75):
            client, stream = self.request()
            self.assertTrue(json.loads(stream.readline())['ok'])
            stream.close()
            client.close()
        _, healthy = self.request()
        self.assertTrue(json.loads(healthy.readline())['ok'])


if __name__ == '__main__':
    unittest.main()
