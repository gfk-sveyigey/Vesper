"""Compile the real Swift Emby client and exercise it against a local HTTP server."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit, parse_qs
import json
import os
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[2]

EVENTS = []
MEDIA = {'Id': 'v2', 'Name': 'Version 2', 'RunTimeTicks': 6000000000, 'Container': 'mkv',
         'MediaStreams': [{'Type': 'Subtitle', 'IsExternal': True, 'Index': 2, 'Codec': 'srt', 'DisplayTitle': '中文'}]}
ITEM = {'Id': 'movie', 'Name': 'Movie', 'Type': 'Movie', 'RunTimeTicks': 6000000000,
        'UserData': {'PlaybackPositionTicks': 300000000}, 'Overview': 'A movie',
        'MediaSources': [dict(MEDIA, Id='v1', Name='Version 1'), MEDIA]}

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        path = urlsplit(self.path)
        if path.path == '/proxy/emby/':
            self.respond({'Id': 'test-server'}); return
        if path.path.startswith('/proxy/emby/Status/'):
            self.send_response(int(path.path.rsplit('/', 1)[1])); self.end_headers(); return
        if path.path == '/proxy/emby/Items/movie/Images/Primary':
            assert self.headers.get('User-Agent') == 'CustomVesper/2.0'
            assert self.headers.get('Accept') == 'image/*,*/*;q=0.8'
            assert self.headers.get('Authorization', '').startswith('Emby UserId="user"')
            assert self.headers.get('X-Emby-Token') == 'secret'
            self.respond({'image': True}); return
        if path.path == '/proxy/emby/Array':
            self.respond([{'Id': '1'}]); return
        if path.path == '/proxy/emby/Users/user/Views':
            self.respond({'Items': [{'Id': 'library', 'Name': 'Movies', 'Type': 'CollectionFolder', 'IsFolder': True}]}); return
        if path.path == '/proxy/emby/Users/user/Items':
            assert parse_qs(path.query)['StartIndex'] == ['100']
            self.respond({'Items': [ITEM, {'Id': 'book', 'Name': 'Book', 'Type': 'Book'}]}); return
        if path.path == '/proxy/emby/Users/user/Items/movie':
            self.respond(ITEM); return
        if path.path == '/proxy/emby/Events':
            self.respond({'Items': EVENTS}); return
        assert path.path == '/proxy/emby/Echo', path.path
        self.respond({'ua': self.headers.get('User-Agent'), 'token': self.headers.get('X-Emby-Token'),
                      'extra': self.headers.get('X-Test'), 'identity': self.headers.get('Authorization'),
                      'term': parse_qs(path.query).get('term', [''])[0]})

    def do_POST(self):
        if self.path == '/proxy/emby/Empty':
            self.send_response(204); self.end_headers(); return
        payload = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        if self.path == '/proxy/emby/Items/movie/PlaybackInfo':
            assert payload['UserId'] == 'user'
            media = dict(MEDIA)
            if not payload['EnableDirectPlay']:
                media['TranscodingUrl'] = '/emby/Videos/movie/master.m3u8?StartTimeTicks=' + str(payload['StartTimeTicks'])
            else:
                assert payload['MediaSourceId'] == 'v2'
                media['DirectStreamUrl'] = '/emby/Videos/movie/stream?static=true&MediaSourceId=v2'
            self.respond({'PlaySessionId': 'server-session', 'MediaSources': [media]}); return
        if self.path == '/proxy/emby/Users/AuthenticateByName':
            assert payload == {'Username': 'alice', 'Pw': 'pw'}
            self.respond({'AccessToken': 'issued-token'}); return
        if '/Sessions/Playing' in self.path:
            EVENTS.append({'path': self.path.removeprefix('/proxy/emby/'), 'body': payload})
            self.send_response(204); self.end_headers(); return
        self.respond(payload)

    def do_DELETE(self):
        if urlsplit(self.path).path == '/proxy/emby/Videos/ActiveEncodings':
            EVENTS.append({'method': 'DELETE', 'query': parse_qs(urlsplit(self.path).query)})
        else:
            assert urlsplit(self.path).path == '/proxy/emby/Empty' 
        self.send_response(204); self.end_headers()

    def respond(self, value):
        data = json.dumps(value).encode()
        self.send_response(200); self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix='vesper-emby-checks-') as temp:
        binary = str(Path(temp) / 'checks')
        subprocess.run([os.environ.get('SWIFTC', 'swiftc'), '-swift-version', '6', '-strict-concurrency=complete',
                        str(ROOT / 'Vesper/Infrastructure/Sources/EmbyAPIClient.swift'),
                        str(ROOT / 'Tests/EmbyAPIClientChecks.swift'), '-o', binary], check=True)
        subprocess.run([binary, 'http://127.0.0.1:' + str(server.server_port)], check=True)
        # Compile the real repository and session. Extract only value contracts
        # from their iOS files; platform/keychain implementations are not tested here.
        source = (ROOT / 'Vesper/Infrastructure/Sources/SourceLibrary.swift').read_text()
        models = source[source.index('/// Stable identity'):source.index('enum SourceFailure:')]
        source = (ROOT / 'Playback/Contracts/PlaybackContracts.swift').read_text()
        models += source[source.index('public struct EngineExternalSubtitle'):source.index('/// Value-only state')]
        source = (ROOT / 'Vesper/Infrastructure/Playback/PlaybackCore.swift').read_text()
        models += source[source.index('struct TranscodedPlaybackResource'):source.index('/// The UI talks')]
        source = (ROOT / 'Vesper/Infrastructure/Playback/PlaybackSession.swift').read_text()
        models += source[source.index('struct PlaybackVideoDetails'):source.index('struct PlaybackQueueInfo')]
        models += "\n@MainActor final class EmbyAccountStore { static let shared = EmbyAccountStore(); func client(for source: MediaSource) throws -> EmbyAPIClient { fatalError(\"Test must inject client\") } }\n"
        contracts = Path(temp) / 'Models.swift'; contracts.write_text('import Foundation\n' + models)
        units = [str(ROOT / 'Vesper/Infrastructure/Sources/EmbyAPIClient.swift'), str(contracts)]
        for name in ['Sources/EmbyIntegration.swift', 'Playback/EmbyPlaybackSession.swift']:
            unit = Path(temp) / Path(name).name
            unit.write_text((ROOT / 'Vesper/Infrastructure' / name).read_text().replace('import PlaybackContracts', ''))
            units.append(str(unit))
        subprocess.run([os.environ.get('SWIFTC', 'swiftc'), '-swift-version', '6', '-strict-concurrency=complete',
                        *units, str(ROOT / 'Tests/EmbyRepositoryChecks.swift'), '-o', binary], check=True)
        subprocess.run([binary, 'http://127.0.0.1:' + str(server.server_port)], check=True)
finally:
    server.shutdown()
