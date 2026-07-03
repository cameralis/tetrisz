/// Backend base URL. Override for local development:
///
///     flutter run --dart-define=TETRIS_BACKEND_URL=http://localhost:8787
///
/// The default points at the production Cloudflare Worker.
const String backendBaseUrl = String.fromEnvironment(
  'TETRIS_BACKEND_URL',
  defaultValue: 'https://tetrisz-backend.szabi.workers.dev',
);

Uri backendHttpUri(String path) {
  final base = Uri.parse(backendBaseUrl);
  return base.replace(path: path);
}

Uri backendWsUri(String path) {
  final base = Uri.parse(backendBaseUrl);
  return base.replace(scheme: base.scheme == 'https' ? 'wss' : 'ws', path: path);
}
