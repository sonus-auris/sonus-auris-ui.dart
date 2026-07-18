// A tiny dependency-free static file server for the built Flutter web app.
// Serves e2e against `build/web` on an ephemeral port; falls back to
// index.html for client-side routes.
import { createReadStream, existsSync, statSync } from 'node:fs';
import http from 'node:http';
import net from 'node:net';
import { extname, join, normalize } from 'node:path';

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.wasm': 'application/wasm',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.otf': 'font/otf',
  '.ttf': 'font/ttf',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.bin': 'application/octet-stream',
  '.symbols': 'application/octet-stream',
};

async function findOpenPort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.on('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const address = server.address();
      if (!address || typeof address !== 'object') {
        reject(new Error('failed to read bound address'));
        return;
      }
      const { port } = address;
      server.close(() => resolve(port));
    });
  });
}

/// Resolves the target the smokes run against: a deployed console URL when
/// `CONSOLE_BASE_URL` is set (the hook the cluster's browser runners use), else
/// a local static server over the freshly-built `build/web`. Returns
/// `{ url, close() }` either way.
export async function resolveTarget(root) {
  const remote = (process.env.CONSOLE_BASE_URL ?? '').trim().replace(/\/+$/, '');
  if (remote) {
    return { url: remote, close: async () => {} };
  }
  return startStaticServer(root);
}

/// Starts serving [root] and resolves to `{ url, close() }`.
export async function startStaticServer(root) {
  if (!existsSync(join(root, 'index.html'))) {
    throw new Error(
      `No build/web found at ${root}. Run: flutter build web --release`,
    );
  }
  const port = await findOpenPort();
  const server = http.createServer((req, res) => {
    // Cross-origin isolation headers so CanvasKit/skwasm can use threads if it
    // wants; harmless otherwise and mirrors a production static host.
    res.setHeader('Cross-Origin-Opener-Policy', 'same-origin');
    res.setHeader('Cross-Origin-Embedder-Policy', 'require-corp');

    const url = new URL(req.url ?? '/', 'http://localhost');
    let pathname = decodeURIComponent(url.pathname);
    if (pathname.endsWith('/')) pathname += 'index.html';

    // Contain traversal within root.
    const resolved = normalize(join(root, pathname));
    if (!resolved.startsWith(normalize(root))) {
      res.statusCode = 403;
      res.end('forbidden');
      return;
    }

    const file =
      existsSync(resolved) && statSync(resolved).isFile()
        ? resolved
        : join(root, 'index.html'); // SPA fallback

    res.setHeader('content-type', MIME[extname(file)] ?? 'application/octet-stream');
    createReadStream(file)
      .on('error', () => {
        res.statusCode = 500;
        res.end('read error');
      })
      .pipe(res);
  });

  await new Promise((resolve) => server.listen(port, '127.0.0.1', resolve));
  return {
    url: `http://127.0.0.1:${port}`,
    close: () => new Promise((resolve) => server.close(resolve)),
  };
}
