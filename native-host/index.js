#!/usr/local/bin/node
'use strict';
// Раньше был "#!/usr/bin/env node" — работает в интерактивном
// шелле (там PATH включает /usr/local/bin), но у GUI-приложений
// на macOS (включая Firefox) PATH урезанный и /usr/local/bin туда
// не входит, поэтому "env" не находил node и процесс не стартовал
// вообще — ДО открытия лог-файла, отсюда полная тишина в host.log
// при каждой реальной попытке расширения подключиться через
// nativeMessaging. Абсолютный путь к node решает это.

// native-host/index.js — native messaging host для TabVPN.
// НЕ спавнит Tor — использует уже запущенный persistent Tor
// (brew services: SocksPort 9050 / ControlPort 9051,
// DataDirectory /usr/local/var/lib/tor). Мост к ControlPort
// с cookie-авторизацией для команд "status" / "newCircuit".

const net = require('net');
const fs = require('fs');
const path = require('path');

const SOCKS_PORT = 9050;
const CONTROL_PORT = 9051;
const CONTROL_HOST = '127.0.0.1';
const LOG_PATH = path.join(__dirname, 'host.log');

// Cookie может лежать в разных местах в зависимости от ОС и от
// того, как поставлен Tor — этот блок перебирает кандидатов.
//
// - macOS: через инсталлятор TabVPN (свой bundled Tor, без
//   Homebrew) или через brew (Intel-путь /usr/local, Apple
//   Silicon-путь /opt/homebrew).
// - Windows: инсталлятор TabVPN кладёт свой Tor в
//   %LOCALAPPDATA%\TabVPN\tor-data.
// - Linux: инсталлятор TabVPN кладёт свой Tor в
//   ~/.local/share/TabVPN/tor-data (XDG data dir), плюс запасной
//   путь системного пакета tor (Debian/Ubuntu и др.), если
//   пользователь такой уже установил сам.
//
// В каждой ветке проверяем кандидатов по порядку, берём первый
// существующий (resolveCookiePath ниже).
function buildCookieCandidates() {
  if (process.platform === 'win32') {
    const localAppData = process.env.LOCALAPPDATA || '';
    return [
      path.join(localAppData, 'TabVPN', 'tor-data', 'control_auth_cookie'),
    ];
  }
  if (process.platform === 'linux') {
    const home = process.env.HOME || '';
    return [
      path.join(home, '.local', 'share', 'TabVPN', 'tor-data', 'control_auth_cookie'),
      '/var/lib/tor/control_auth_cookie',
    ];
  }
  // По умолчанию — macOS (darwin), поведение как было раньше.
  const home = process.env.HOME || '';
  return [
    path.join(home, 'Library', 'Application Support', 'TabVPN', 'tor-data', 'control_auth_cookie'),
    '/opt/homebrew/var/lib/tor/control_auth_cookie',
    '/usr/local/var/lib/tor/control_auth_cookie',
  ];
}

const COOKIE_CANDIDATES = buildCookieCandidates();

function resolveCookiePath() {
  for (const p of COOKIE_CANDIDATES) {
    try {
      if (fs.existsSync(p)) return p;
    } catch (err) {
      // пропускаем недоступный путь, пробуем следующий
    }
  }
  // ни один не нашёлся — вернём последний как путь по умолчанию,
  // чтобы сообщение об ошибке ниже было информативным
  return COOKIE_CANDIDATES[COOKIE_CANDIDATES.length - 1];
}

function log(line) {
  try {
    fs.appendFileSync(LOG_PATH, `[${new Date().toISOString()}] ${line}\n`);
  } catch (err) {
    // логирование не должно ронять процесс
  }
}

// ---------- Tor ControlPort client ----------
// Один сокет на команду: connect -> AUTHENTICATE -> <command> -> close.

function sendControlCommand(command) {
  return new Promise((resolve) => {
    let cookieHex;
    try {
      cookieHex = fs.readFileSync(resolveCookiePath()).toString('hex');
    } catch (err) {
      resolve({ ok: false, error: 'Не найден cookie авторизации: ' + err.message });
      return;
    }

    const socket = net.connect(CONTROL_PORT, CONTROL_HOST);
    let buf = '';
    let stage = 'auth'; // 'auth' -> 'command'
    let settled = false;

    const timer = setTimeout(() => finish({ ok: false, error: 'control_timeout' }), 5000);

    function finish(result) {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      socket.removeAllListeners();
      socket.destroy();
      resolve(result);
    }

    socket.on('error', (err) => {
      finish({ ok: false, error: 'Ошибка соединения с control port: ' + err.message });
    });

    socket.on('connect', () => {
      socket.write(`AUTHENTICATE ${cookieHex}\r\n`);
    });

    socket.on('data', (chunk) => {
      buf += chunk.toString();

      if (stage === 'auth') {
        if (!buf.includes('\r\n')) return;
        if (!buf.startsWith('250')) {
          finish({ ok: false, error: 'Ошибка авторизации: ' + buf.trim() });
          return;
        }
        buf = '';
        stage = 'command';
        socket.write(command + '\r\n');
        return;
      }

      // Финал и для одно-, и для многострочных (GETINFO) ответов —
      // строка "250 OK\r\n" в конце.
      if (buf.endsWith('250 OK\r\n')) {
        finish({ ok: true, raw: buf.trim() });
      } else if (/^\d{3} /.test(buf) && buf.endsWith('\r\n') && !buf.includes('250 OK')) {
        finish({ ok: false, error: buf.trim() });
      }
    });
  });
}

function checkSocksListening() {
  return new Promise((resolve) => {
    const socket = net.connect(SOCKS_PORT, '127.0.0.1');
    const t = setTimeout(() => { socket.destroy(); resolve(false); }, 2000);
    socket.on('connect', () => { clearTimeout(t); socket.end(); resolve(true); });
    socket.on('error', () => { clearTimeout(t); resolve(false); });
  });
}

async function requestStatus() {
  const socksUp = await checkSocksListening();
  if (!socksUp) return { ready: false, port: null };
  const bootstrap = await sendControlCommand('GETINFO status/bootstrap-phase');
  const ready = bootstrap.ok && /PROGRESS=100/.test(bootstrap.raw);
  return { ready, port: ready ? SOCKS_PORT : null };
}

async function requestNewCircuit() {
  const res = await sendControlCommand('SIGNAL NEWNYM');
  return { ok: res.ok, error: res.ok ? null : res.error };
}

// --- native messaging протокол (stdio, 4-байтовый LE префикс длины) ---

let inputBuffer = Buffer.alloc(0);

process.stdin.on('data', (chunk) => {
  inputBuffer = Buffer.concat([inputBuffer, chunk]);
  processInputBuffer();
});

function processInputBuffer() {
  while (inputBuffer.length >= 4) {
    const length = inputBuffer.readUInt32LE(0);
    if (inputBuffer.length < 4 + length) return;
    const messageBytes = inputBuffer.slice(4, 4 + length);
    inputBuffer = inputBuffer.slice(4 + length);
    let message;
    try {
      message = JSON.parse(messageBytes.toString('utf8'));
    } catch (err) {
      log('Не удалось разобрать сообщение от расширения: ' + err.message);
      continue;
    }
    handleMessage(message);
  }
}

function sendMessage(obj) {
  const json = Buffer.from(JSON.stringify(obj), 'utf8');
  const header = Buffer.alloc(4);
  header.writeUInt32LE(json.length, 0);
  process.stdout.write(Buffer.concat([header, json]));
}

async function handleMessage(message) {
  if (!message || typeof message.command !== 'string') return;
  log('Команда от расширения: ' + message.command);

  if (message.command === 'status') {
    const { ready, port } = await requestStatus();
    sendMessage({ type: 'status', ready, port });
  } else if (message.command === 'newCircuit') {
    const { ok, error } = await requestNewCircuit();
    sendMessage({ type: 'newCircuitResult', ok, error });
  }
}

process.stdin.on('end', () => {
  log('stdin закрыт расширением, завершаемся');
  process.exit(0);
});

// Без этого любая необработанная ошибка (напр. в промисе
// sendControlCommand/requestStatus) убивала процесс МОЛЧА — в
// host.log не оставалось никакого следа, и со стороны расширения
// это выглядело неотличимо от штатного отключения: onDisconnect
// срабатывал, scheduleReconnect() пытался переподключиться, но
// если причина падения не зависела от состояния (напр. гонка при
// старте), цикл падение-реконнект мог повторяться бесконечно без
// единой диагностической строки в логе.
process.on('uncaughtException', (err) => {
  log('КРИТИЧЕСКАЯ ОШИБКА (uncaughtException), процесс падает: ' + (err && err.stack || err));
  process.exit(1);
});
process.on('unhandledRejection', (reason) => {
  log('КРИТИЧЕСКАЯ ОШИБКА (unhandledRejection), процесс падает: ' + (reason && reason.stack || reason));
  process.exit(1);
});

log('--- native host запущен (persistent Tor на 127.0.0.1:' + SOCKS_PORT + ') ---');
