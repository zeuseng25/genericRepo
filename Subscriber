import React from 'react';
import { sendConnectionLog } from './api/connectionLog'; // kendi import'un
import { mapNtfyToNotification } from './utils/ntfyMapper'; // kendi import'un

class NotificationSubscriber extends React.Component {
  // ============================================================
  // STATE
  // ============================================================
  state = {
    resolvedTopic: this.props.topic || null,
    connection: {
      status: 'idle',     // idle | connecting | connected | error
      topic: null,
      error: null,
      ts: null,
    },
    notifications: [],
  };

  // ============================================================
  // INSTANCE FIELDS (state dışı, render tetiklemez)
  // ============================================================
  esRef = null;
  sseBuffer = [];
  flushTimer = null;
  reconnectTimer = null;
  reconnectAttempt = 0;
  lastErrorLogTs = 0;
  errorLogInFlight = false;
  isStopped = false;

  // ============================================================
  // LIFECYCLE
  // ============================================================
  componentDidMount() {
    this.isStopped = false;
    if (this.state.resolvedTopic) {
      this.startSSE();
    }
  }

  componentDidUpdate(prevProps, prevState) {
    // Topic değiştiyse eski bağlantıyı kapat, yenisini aç
    if (prevState.resolvedTopic !== this.state.resolvedTopic) {
      this.startSSE();
    }
  }

  componentWillUnmount() {
    this.isStopped = true;
    this.stopSSE();
    if (this.flushTimer) {
      clearTimeout(this.flushTimer);
      this.flushTimer = null;
    }
  }

  // ============================================================
  // URL BUILDER
  // ============================================================
  buildSseUrl = (topic) => {
    const { hostname, protocol } = window.location;
    const isLocal =
      hostname === 'localhost' ||
      hostname === '127.0.0.1' ||
      hostname.startsWith('192.168.') ||
      hostname.endsWith('.local');

    if (isLocal) {
      return `http://localhost:9393/${topic}/sse`;
    }
    return `${protocol}//${hostname}/${topic}/sse`;
  };

  // ============================================================
  // CONNECTION LOG (rate-limited)
  // ============================================================
  safeSendConnectionLog = (statusCode, message, meta = {}) => {
    const now = Date.now();
    if (now - this.lastErrorLogTs < 10000) return; // 10sn throttle
    if (this.errorLogInFlight) return;

    this.lastErrorLogTs = now;
    this.errorLogInFlight = true;

    try {
      Promise.resolve(sendConnectionLog(statusCode, message, meta))
        .catch((logErr) =>
          console.error('Connection log gönderilemedi:', logErr)
        )
        .finally(() => {
          this.errorLogInFlight = false;
        });
    } catch (logErr) {
      this.errorLogInFlight = false;
      console.error('Connection log gönderilemedi:', logErr);
    }
  };

  // ============================================================
  // STOP (cleanup)
  // ============================================================
  stopSSE = () => {
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    if (this.esRef) {
      try {
        // Önce handler'ları unbind et ki close son bir error tetiklemesin
        this.esRef.onopen = null;
        this.esRef.onmessage = null;
        this.esRef.onerror = null;
        this.esRef.close();
      } catch (_) {}
      this.esRef = null;
    }
  };

  // ============================================================
  // START SSE (idempotent — birden fazla çağrılabilir)
  // ============================================================
  startSSE = () => {
    // 1) Önce eskisini temizle (LEAK FIX)
    this.stopSSE();

    if (this.isStopped) return;

    const { resolvedTopic } = this.state;
    if (!resolvedTopic) return;

    this.setState({
      connection: {
        status: 'connecting',
        topic: resolvedTopic,
        error: null,
        ts: Date.now(),
      },
    });

    const sseUrl = this.buildSseUrl(resolvedTopic);
    let es;
    try {
      es = new EventSource(sseUrl, { withCredentials: false });
    } catch (initErr) {
      this.safeSendConnectionLog('500', 'EventSource init failed', {
        topic: resolvedTopic,
        error: initErr.message,
      });
      this.scheduleReconnect();
      return;
    }
    this.esRef = es;

    // --- onopen ---
    es.onopen = () => {
      if (es !== this.esRef) return; // eski instance'tan geç gelen event
      this.reconnectAttempt = 0;
      this.lastErrorLogTs = 0;
      this.setState({
        connection: {
          status: 'connected',
          topic: resolvedTopic,
          error: null,
          ts: Date.now(),
        },
      });
      this.safeSendConnectionLog('200', 'SSE bağlantısı başarılı', {
        topic: resolvedTopic,
      });
    };

    // --- onmessage ---
    es.onmessage = (e) => {
      if (es !== this.esRef) return;
      try {
        const d = JSON.parse(e.data);
        if (d.event && d.event !== 'message') return;
        this.sseBuffer.push(mapNtfyToNotification(d));
        this.scheduleFlush();
      } catch (err) {
        console.error('SSE parse error', err, e.data);
      }
    };

    // --- onerror ---
    es.onerror = () => {
      if (es !== this.esRef) return; // zombi connection'ı yoksay

      const readyState = es.readyState; // 0=CONNECTING, 2=CLOSED

      this.setState({
        connection: {
          status: 'error',
          topic: resolvedTopic,
          error: {
            readyState,
            online: navigator.onLine,
          },
          ts: Date.now(),
        },
      });

      this.safeSendConnectionLog(
        '502',
        `SSE bağlantı hatası (readyState=${readyState})`,
        {
          topic: resolvedTopic,
          readyState,
          online: navigator.onLine,
        }
      );

      // Sadece tamamen kapandıysa manuel reconnect
      // (readyState=0 ise browser zaten kendi auto-reconnect'ini yapıyor)
      if (readyState === EventSource.CLOSED) {
        this.stopSSE();
        this.scheduleReconnect();
      }
    };
  };

  // ============================================================
  // RECONNECT (exponential backoff)
  // ============================================================
  scheduleReconnect = () => {
    if (this.isStopped) return;
    if (this.reconnectTimer) return; // zaten zamanlanmış

    this.reconnectAttempt += 1;
    const delay = Math.min(1000 * 2 ** this.reconnectAttempt, 30000);

    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this.startSSE();
    }, delay);
  };

  // ============================================================
  // FLUSH (buffer → state, batch)
  // ============================================================
  scheduleFlush = () => {
    if (this.flushTimer) return;
    this.flushTimer = setTimeout(() => {
      this.flushTimer = null;
      if (this.sseBuffer.length === 0) return;
      const batch = this.sseBuffer.splice(0, this.sseBuffer.length);
      this.setState((prev) => ({
        notifications: [...batch, ...prev.notifications],
      }));
    }, 200); // 200ms throttle
  };

  // ============================================================
  // RENDER
  // ============================================================
  render() {
    const { connection, notifications } = this.state;
    return (
      <div className="notification-subscriber">
        <div className="status-bar">
          <span className={`status status-${connection.status}`}>
            {connection.status}
          </span>
          {connection.error && (
            <small>
              readyState={connection.error.readyState} | online=
              {String(connection.error.online)}
            </small>
          )}
        </div>
        <ul>
          {notifications.map((n) => (
            <li key={n.id}>{n.title}</li>
          ))}
        </ul>
      </div>
    );
  }
}

export default NotificationSubscriber;
