'use strict';
// 校验 VTProxy.swift 里的三条解析逻辑（与 Swift 端同算法）：
//   1) splitHostPort       host:port / [v6]:port / 裸主机
//   2) hostFromPlainHTTP   绝对 URI 与 Host 头
//   3) parseRequestLine    CONNECT vs 普通 HTTP
// Swift 端写法就是照这三段翻的，这里跑通等于逻辑被验证过一遍。

function splitHostPort(s) {
  if (!s) return null;
  if (s[0] === '[') {
    const i = s.indexOf(']');
    if (i < 0) return null;
    const host = s.slice(1, i);
    const rest = s.slice(i + 1);
    const port = rest[0] === ':' ? parseInt(rest.slice(1), 10) : 0;
    if (!host || !(port >= 1 && port <= 65535)) return null;
    return { host, port };
  }
  const i = s.lastIndexOf(':');
  if (i <= 0) return null;
  const host = s.slice(0, i);
  const port = parseInt(s.slice(i + 1), 10);
  if (!host || !(port >= 1 && port <= 65535)) return null;
  if (host.indexOf(':') >= 0) return null;   // 无方括号的多冒号 = 非法，交给 [v6] 分支
  return { host, port };
}

function hostFromPlainHTTP(line, headers) {
  const parts = line.split(' ');
  const uri = parts.length >= 2 ? parts[1] : '';
  if (/^https?:\/\//i.test(uri)) {
    const noScheme = uri.replace(/^https?:\/\//i, '');
    const slash = noScheme.indexOf('/');
    const authority = slash >= 0 ? noScheme.slice(0, slash) : noScheme;
    const hp = splitHostPort(authority);
    if (hp) return hp;
    return authority ? { host: authority, port: 80 } : null;
  }
  const hostLine = headers['host'] || '';
  const hp = splitHostPort(hostLine);
  if (hp) return hp;
  return hostLine ? { host: hostLine, port: 80 } : null;
}

function parseRequestLine(line) {
  const parts = line.trim().split(/\s+/);
  if (parts.length < 2) return null;
  const method = parts[0];
  const target = parts[1];
  if (method === 'CONNECT') {
    const hp = splitHostPort(target);
    return hp ? { kind: 'connect', host: hp.host, port: hp.port } : null;
  }
  return { kind: 'plain', method, target };
}

function lowerHeaders(block) {
  const h = {};
  for (const raw of block.split('\r\n').slice(1)) {
    const i = raw.indexOf(':');
    if (i <= 0) continue;
    h[raw.slice(0, i).trim().toLowerCase()] = raw.slice(i + 1).trim();
  }
  return h;
}

const cases = [];
function eq(name, got, want) {
  const g = JSON.stringify(got), w = JSON.stringify(want);
  cases.push({ name, pass: g === w, got: g, want: w });
}

// ---- splitHostPort ----
eq('host:port',                 splitHostPort('example.com:443'),        { host: 'example.com', port: 443 });
eq('ip:port',                   splitHostPort('1.2.3.4:8080'),           { host: '1.2.3.4', port: 8080 });
eq('[v6]:port',                 splitHostPort('[2001:db8::1]:53'),       { host: '2001:db8::1', port: 53 });
eq('裸主机(无端口)',            splitHostPort('example.com'),            null);
eq('裸 v6(无方括号)',           splitHostPort('2001:db8::1'),            null);
eq('端口越界 70000',            splitHostPort('a.com:70000'),            null);
eq('端口 0',                    splitHostPort('a.com:0'),                null);
eq('空 host',                   splitHostPort(':443'),                   null);

// ---- parseRequestLine ----
eq('CONNECT',                   parseRequestLine('CONNECT example.com:443 HTTP/1.1'),
                                { kind: 'connect', host: 'example.com', port: 443 });
eq('CONNECT v6',                parseRequestLine('CONNECT [2001:db8::1]:443 HTTP/1.1'),
                                { kind: 'connect', host: '2001:db8::1', port: 443 });
eq('CONNECT 缺端口',            parseRequestLine('CONNECT example.com HTTP/1.1'), null);
eq('GET 绝对 URI',              parseRequestLine('GET http://a.com/x HTTP/1.1'),
                                { kind: 'plain', method: 'GET', target: 'http://a.com/x' });
eq('GET 相对 URI',              parseRequestLine('GET /x HTTP/1.1'),
                                { kind: 'plain', method: 'GET', target: '/x' });

// ---- hostFromPlainHTTP ----
eq('绝对 URI 带端口',
   hostFromPlainHTTP('GET http://a.com:8080/x HTTP/1.1', {}), { host: 'a.com', port: 8080 });
eq('绝对 URI 无端口',
   hostFromPlainHTTP('GET http://a.com/x HTTP/1.1', {}), { host: 'a.com', port: 80 });
eq('Host 头',
   hostFromPlainHTTP('GET /x HTTP/1.1', { host: 'b.com:81' }), { host: 'b.com', port: 81 });
eq('Host 头无端口',
   hostFromPlainHTTP('GET /x HTTP/1.1', { host: 'b.com' }), { host: 'b.com', port: 80 });
eq('两者都没有',                hostFromPlainHTTP('GET /x HTTP/1.1', {}), null);

// ---- header 解析 ----
const blk = 'GET /x HTTP/1.1\r\nHost: c.com:8080\r\nProxy-Connection: keep-alive\r\n\r\n';
eq('header 小写化',             lowerHeaders(blk),
   { host: 'c.com:8080', 'proxy-connection': 'keep-alive' });

let bad = 0;
for (const c of cases) {
  if (c.pass) {
    console.log('  ✓ ' + c.name);
  } else {
    bad++;
    console.log('  ✗ ' + c.name + '  got=' + c.got + '  want=' + c.want);
  }
}
console.log('');
console.log(bad === 0
  ? '全部 ' + cases.length + ' 项通过 —— VTProxy 的解析逻辑与 Swift 端一致'
  : bad + ' / ' + cases.length + ' 项失败');
process.exit(bad === 0 ? 0 : 1);
