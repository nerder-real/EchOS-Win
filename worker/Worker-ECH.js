const WS_READY_STATE_OPEN = 1;
const WS_READY_STATE_CLOSING = 2;
const CF_FALLBACK_IPS = ['ProxyIP.CMLiussss.net'];// cm维护

// 代码写死的兜底 token：环境变量 TOKEN 优先，未设置时用此值。
// 留空 = 要求 App 也必须留空才能连；App 填了任意非空值会被拒绝（401）。
const DEFAULT_TOKEN = '';

// 复用 TextEncoder，避免重复创建
const encoder = new TextEncoder();

import { connect } from 'cloudflare:sockets';

export default {
  async fetch(request, env, ctx) {
    try {
      const token = env.TOKEN || DEFAULT_TOKEN; // 环境变量优先，代码写死兜底
      const upgradeHeader = request.headers.get('Upgrade');
      
      if (!upgradeHeader || upgradeHeader.toLowerCase() !== 'websocket') {
        return new URL(request.url).pathname === '/' 
          ? new Response('WebSocket Proxy Server', { status: 200 })
          : new Response('Expected WebSocket', { status: 426 });
      }

      // 无论 token 是否为空都校验：App 填的必须与服务端生效值完全一致，
      // 不一致（包括服务端为空而 App 填了值）一律 401 拒绝。
      if ((request.headers.get('Sec-WebSocket-Protocol') || '') !== token) {
        return new Response('Unauthorized', { status: 401 });
      }

      const [client, server] = Object.values(new WebSocketPair());
      server.accept();

      // 必须挂 ctx.waitUntil：fetch 返回 101 后运行时若没有存活的引用，
      // 会回收 isolate —— 池里借出的空连接发 CONNECT 时无响应（2026-11-15
      // 实测借出 10 次全死）。挂上后 isolate 存活到会话结束。
      ctx.waitUntil(handleSession(server).catch(() => safeCloseWebSocket(server)));

      // 修复 spread 类型错误
      const responseInit = {
        status: 101,
        webSocket: client
      };
      
      if (token) {
        responseInit.headers = { 'Sec-WebSocket-Protocol': token };
      }

      return new Response(null, responseInit);
      
    } catch (err) {
      return new Response(err.toString(), { status: 500 });
    }
  },
};

async function handleSession(webSocket) {
  let remoteSocket, remoteWriter, remoteReader;
  let isClosed = false;

  // 空连接应用层保活（v1.3.0 连接池配套）：客户端会把「已完成 WS 升级、
  // 还没发 CONNECT」的连接预热在池里（TTL 20s），本端在收到 CONNECT 之前
  // 没有任何事件 —— CF 平台对无活动的 isolate 会快速挂起/回收，实测池里
  // 的连接借出时全部无响应。每 10s 发一条文本保活帧刷新所有空闲计时；
  // 客户端对 CONNECTED 之前的未知文本一律忽略（simple_ws.go Read）。
  // 收到 CONNECT / 连接关闭时停止：之后的连接已进入正常透传。
  let idleKeepalive = setInterval(() => {
    try { webSocket.send('PING'); } catch {}
  }, 10000);
  const stopIdleKeepalive = () => { clearInterval(idleKeepalive); idleKeepalive = null; };

  const cleanup = () => {
    if (isClosed) return;
    isClosed = true;
    stopIdleKeepalive();

    try { remoteWriter?.releaseLock(); } catch {}
    try { remoteReader?.releaseLock(); } catch {}
    try { remoteSocket?.close(); } catch {}
    
    remoteWriter = remoteReader = remoteSocket = null;
    safeCloseWebSocket(webSocket);
  };

  const pumpRemoteToWebSocket = async () => {
    try {
      while (!isClosed && remoteReader) {
        const { done, value } = await remoteReader.read();
        
        if (done) break;
        if (webSocket.readyState !== WS_READY_STATE_OPEN) break;
        if (value?.byteLength > 0) webSocket.send(value);
      }
    } catch {}
    
    if (!isClosed) {
      try { webSocket.send('CLOSE'); } catch {}
      cleanup();
    }
  };

  const parseAddress = (addr) => {
    if (addr[0] === '[') {
      const end = addr.indexOf(']');
      return {
        host: addr.substring(1, end),
        port: parseInt(addr.substring(end + 2), 10)
      };
    }
    const sep = addr.lastIndexOf(':');
    return {
      host: addr.substring(0, sep),
      port: parseInt(addr.substring(sep + 1), 10)
    };
  };

  const isCFError = (err) => {
    const msg = err?.message?.toLowerCase() || '';
    return msg.includes('proxy request') || 
           msg.includes('cannot connect') || 
           msg.includes('cloudflare');
  };

  // 单次 connect 超时：目标/中转不可达时快速失败换下一个，而不是挂到平台回收。
  const withTimeout = (promise, ms) => Promise.race([
    promise,
    new Promise((_, reject) => setTimeout(() => reject(new Error('connect timeout')), ms)),
  ]);

  const connectToRemote = async (targetAddr, firstFrameData) => {
    const { host, port } = parseAddress(targetAddr);
    const attempts = [null, ...CF_FALLBACK_IPS];

    for (let i = 0; i < attempts.length; i++) {
      try {
        remoteSocket = connect({
          hostname: attempts[i] || host,
          port
        });

        if (remoteSocket.opened) await withTimeout(remoteSocket.opened, 6000);

        remoteWriter = remoteSocket.writable.getWriter();
        remoteReader = remoteSocket.readable.getReader();

        // 发送首帧数据
        if (firstFrameData) {
          await remoteWriter.write(encoder.encode(firstFrameData));
        }

        webSocket.send('CONNECTED');
        pumpRemoteToWebSocket();
        return;

      } catch (err) {
        // 清理失败的连接
        try { remoteWriter?.releaseLock(); } catch {}
        try { remoteReader?.releaseLock(); } catch {}
        try { remoteSocket?.close(); } catch {}
        remoteWriter = remoteReader = remoteSocket = null;

        // 如果不是 CF 错误或已是最后尝试，抛出错误
        if (!isCFError(err) || i === attempts.length - 1) {
          throw err;
        }
      }
    }
  };

  webSocket.addEventListener('message', async (event) => {
    if (isClosed) return;

    try {
      const data = event.data;

      if (typeof data === 'string') {
        if (data.startsWith('CONNECT:')) {
          // 收到 CONNECT：连接进入正常透传，空连接保活使命完成
          stopIdleKeepalive();
          const sep = data.indexOf('|', 8);
          await connectToRemote(
            data.substring(8, sep),
            data.substring(sep + 1)
          );
        }
        else if (data.startsWith('DATA:')) {
          if (remoteWriter) {
            await remoteWriter.write(encoder.encode(data.substring(5)));
          }
        }
        else if (data === 'CLOSE') {
          cleanup();
        }
      }
      else if (data instanceof ArrayBuffer && remoteWriter) {
        await remoteWriter.write(new Uint8Array(data));
      }
    } catch (err) {
      try { webSocket.send('ERROR:' + err.message); } catch {}
      cleanup();
    }
  });

  webSocket.addEventListener('close', cleanup);
  webSocket.addEventListener('error', cleanup);
}

function safeCloseWebSocket(ws) {
  try {
    if (ws.readyState === WS_READY_STATE_OPEN || 
        ws.readyState === WS_READY_STATE_CLOSING) {
      ws.close(1000, 'Server closed');
    }
  } catch {}
}
