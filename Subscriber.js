import React from 'react';
import { sendConnectionLog } from './api/connectionLog';
import { mapNtfyToNotification } from './utils/ntfyMapper';

// ============================================================
// CONSTANTS
// ============================================================
const MAX_RECONNECT_ATTEMPTS = 3;
const FLUSH_INTERVAL_MS = 200;
const LOG_THROTTLE_MS = 10000;
const RECONNECT_MAX_DELAY_MS = 30000;

// ============================================================
// COMPONENT
// ============================================================
class NotificationSubscriber extends React.Component {
  // ----------------------------------------------------------
  // STATE — sadece render'ı etkileyenler
  // ----------------------------------------------------------
  state = {
    resolvedTopic: this.props.topic || null,
    connection: {
      status: 'idle',  // idle | connecting | connected | error | failed
      topic: null,
      error: null,
      attempt: 0,
      ts: null,
    },
    notifications: [],
  };

  // ----------------------------------------------------------
  // INSTANCE FIELDS — render tetiklemez, hızlı erişim
  // ----------------------------------------------------------
  // Connection
  esRef = null;
  esGeneration = 0;        // her yeni connection için artar, zombi guard

  // Timers
  reconnectTimer = null;
  flushTimer = null;

  // Counters & timestamps
  reconnectAttempt = 0;
  lastOpenTs = null;
  lastMessageTs = null;
  messagesReceivedCount = 0;

  // Log throttling
  lastErrorLogTs = 0;
  errorLogInFlight = false;

  // Buffers
  sseBuffer = [];

  // Lifecycle guards
  isUnmounted = false;     // setState'leri korur
  isStopped = false;       // reconnect'i durdurur

  // Optional network listeners
  onlineListener = null;
  offlineListener = null;

  // ----------------------------------------------------------
  // LIFECYCLE
  // ----------------------------------------------------------
  componentDidMount() {
    this.isUnmounted = false;
    this.isStopped = false;
    this.attachNetworkListeners();
    if (this.state.resolvedTopic) {
      this.startSSE();
    }
  }

  static getDerivedStateFromProps(props, state) {
    if (props.topic !== state.resolvedTopic) {
      return { resolvedTopic: props.topic };
    }
    return null;
  }

  componentDidUpdate(prevProps, prevState) {
    if (prevState.resolvedTopic !== this.state.resolvedTopic) {
      this.reconnectAttempt = 0;
      this.startSSE();
    }
  }

  componentWillUnmount() {
    // SIRA ÖNEMLİ — önce flag'leri set et, sonra cleanup
    this.isUnmounted = true;
    this.isStopped = true;

    this.stopSSE();
    this.detachNetworkListeners();

    if (this.flushTimer) {
      clearTimeout(this.flushTimer);
      this.flushTimer = null;
    }

    // sseBuffer'ı boşalt, GC için
    this.sseBuffer = [];
  }

  // ----------------------------------------------------------
  // NETWORK LISTENERS
  // ----------------------------------------------------------
  attachNetworkListeners = () => {
    this.onlineListener = () => {
      // Online olunca elimizde failed/error varsa hemen tekrar dene
      const status = this.state.connection.status;
      if ((status === 'error' || status === 'failed') && !this.isStopped) {
        this.reconnectAttempt = 0;
        this.startSSE();
      }
    };
    this.offlineListener = () => {
      this.safeSendConnectionLog('418', 'Client gitti offline', {
        operation: 'subscribe',
        phase: 'client_offline',
        topic: this.state.resolvedTopic,
      });
    };
    window.addEventListener('online', this.onlineListener);
    window.addEventListener('offline', this.offlineListener);
  };

  detachNetworkListeners = () => {
    if (this.onlineListener) {
      window.removeEventListener('online', this.onlineListener);
      this.onlineListener = null;
    }
    if (this.offlineListener) {
      window.removeEventListener('offline', this.offlineListener);
      this.offlineListener = null;
    }
  };

  // ----------------------------------------------------------
  // URL BUILDER
  // ----------------------------------------------------------
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

  // ----------------------------------------------------------
  // SAFE setState — unmount sonrası setState yapma
  // ----------------------------------------------------------
  safeSetState = (updater) => {
    if (this.isUnmounted) return;
    this.setState(updater);
  };

  // ----------------------------------------------------------
  // CONNECTION LOG (rate-limited, guarded)
  // ----------------------------------------------------------
  safeSendConnectionLog = (statusCode, message, meta = {}, force = false) => {
    const now = Date.now();
    if (!force && now - this.lastErrorLogTs < LOG_THROTTLE_MS) return;
    if (!force && this.errorLogInFlight) return;

    this.lastErrorLogTs = now;
    this.errorLogInFlight = true;

    const enrichedMeta = {
      ...meta,
      online: navigator.onLine,
      visibilityState: document.visibilityState,
      userAgent: navigator.userAgent,
      pageUrl: window.location.pathname,
      timestamp: new Date().toISOString(),
    };

    try {
      Promise.resolve(sendConnectionLog(statusCode, message, enrichedMeta))
        .catch((logErr) => {
          // Sessizce yut — sonsuz döngü engellemek için
          // eslint-disable-next-line no-console
          console.error('Connection log gönderilemedi:', logErr);
        })
        .finally(() => {
          this.errorLogInFlight = false;
        });
    } catch (logErr) {
      this.errorLogInFlight = false;
      // eslint-disable-next-line no-console
      console.error('Connection log gönderilemedi:', logErr);
    }
  };

  // ----------------------------------------------------------
  // STOP — clean teardown (idempotent)
  // ----------------------------------------------------------
  stopSSE = () => {
    // Reconnect timer'ı iptal et
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }

    // EventSource'u temizle
    if (this.esRef) {
      const es = this.esRef;
      this.esRef = null;
      try {
        // ÖNCE handler'ları unbind et, SONRA close —
        // close son bir error event tetiklemesin
        es.onopen = null;
        es.onmessage = null;
        es.onerror = null;
        es.close();
      } catch (_) {
        // ignore
      }
    }
  };

  // ----------------------------------------------------------
  // START — yeni connection aç (idempotent)
  // ----------------------------------------------------------
  startSSE = () => {
    // Her zaman önce eskisini temizle — LEAK FIX
    this.stopSSE();

    // Kapatma sinyali geldiyse açma
    if (this.isStopped || this.isUnmounted) return;

    const topic = this.state.resolvedTopic;
    if (!topic) return;

    // Her yeni EventSource için generation artır
    // Zombi event guard'ı için kullanılır
    this.esGeneration += 1;
    const myGeneration = this.esGeneration;

    this.safeSetState({
      connection: {
        status: 'connecting',
        topic,
        error: null,
        attempt: this.reconnectAttempt,
        ts: Date.now(),
      },
    });

    const url = this.buildSseUrl(topic);
    let es;
    try {
      es = new EventSource(url, { withCredentials: false });
    } catch (initErr) {
      this.safeSendConnectionLog(
        '500',
        `EventSource init hatası: ${initErr.message}`,
        {
          operation: 'subscribe',
          phase: 'init',
          topic,
        },
        true
      );
      this.scheduleReconnect();
      return;
    }
    this.esRef = es;

    // ----- onopen -----
    es.onopen = () => {
      // Zombi guard: aynı generation mı?
      if (
        this.isUnmounted ||
        this.esRef !== es ||
        this.esGeneration !== myGeneration
      ) {
        return;
      }

      const now = Date.now();
      this.lastOpenTs = now;
      this.lastMessageTs = now;
      this.messagesReceivedCount = 0;
      this.reconnectAttempt = 0;
      this.lastErrorLogTs = 0; // başarılı bağlantıda throttle reset

      this.safeSetState({
        connection: {
          status: 'connected',
          topic,
          error: null,
          attempt: 0,
          ts: now,
        },
      });

      this.safeSendConnectionLog('200', 'SSE bağlantısı başarılı', {
        operation: 'subscribe',
        phase: 'open',
        topic,
        attempt: 0,
      });
    };

    // ----- onmessage -----
    es.onmessage = (e) => {
      if (
        this.isUnmounted ||
        this.esRef !== es ||
        this.esGeneration !== myGeneration
      ) {
        return;
      }

      this.lastMessageTs = Date.now();
      this.messagesReceivedCount += 1;

      try {
        const d = JSON.parse(e.data);
        if (d.event && d.event !== 'message') return; // keepalive/open
        this.sseBuffer.push(mapNtfyToNotification(d));
        this.scheduleFlush();
      } catch (err) {
        // eslint-disable-next-line no-console
        console.error('SSE parse error', err);
        this.safeSendConnectionLog(
          '422',
          'SSE message parse error',
          {
            operation: 'subscribe',
            phase: 'parse',
            topic,
            errorMessage: err.message,
          }
        );
      }
    };

    // ----- onerror -----
    es.onerror = () => {
      // Zombi guard
      if (
        this.isUnmounted ||
        this.esRef !== es ||
        this.esGeneration !== myGeneration
      ) {
        return;
      }

      const readyState = es.readyState;
      const now = Date.now();
      const connectionDurationMs = this.lastOpenTs
        ? now - this.lastOpenTs
        : null;
      const timeSinceLastMessageMs = this.lastMessageTs
        ? now - this.lastMessageTs
        : null;

      this.safeSetState({
        connection: {
          status: 'error',
          topic,
          error: {
            readyState,
            online: navigator.onLine,
            connectionDurationMs,
          },
          attempt: this.reconnectAttempt,
          ts: now,
        },
      });

      // Anlamlı context'le logla
      const statusCode =
        readyState === EventSource.CLOSED ? '503' : '502';

      this.safeSendConnectionLog(
        statusCode,
        `SSE disconnect (readyState=${readyState})`,
        {
          operation: 'subscribe',
          phase: 'sse_runtime',
          topic,
          readyState,
          connectionDurationMs,
          timeSinceLastMessageMs,
          messagesReceived: this.messagesReceivedCount,
          attempt: this.reconnectAttempt,
        }
      );

      // Tamamen kapandıysa manuel reconnect
      // (CONNECTING=0 ise EventSource zaten kendi auto-reconnect'ini yapar)
      if (readyState === EventSource.CLOSED) {
        this.stopSSE();
        this.scheduleReconnect();
      }
    };
  };

  // ----------------------------------------------------------
  // RECONNECT (capped, exponential backoff)
  // ----------------------------------------------------------
  scheduleReconnect = () => {
    if (this.isStopped || this.isUnmounted) return;
    if (this.reconnectTimer) return; // zaten zamanlanmış

    // Limit kontrolü
    if (this.reconnectAttempt >= MAX_RECONNECT_ATTEMPTS) {
      this.safeSetState({
        connection: {
          status: 'failed',
          topic: this.state.resolvedTopic,
          error: { reason: 'max_attempts_reached' },
          attempt: this.reconnectAttempt,
          ts: Date.now(),
        },
      });

      // "Pes ettim" log'u — throttle'a takılmasın
      this.safeSendConnectionLog(
        '504',
        `SSE giving up after ${MAX_RECONNECT_ATTEMPTS} attempts`,
        {
          operation: 'subscribe',
          phase: 'give_up',
          topic: this.state.resolvedTopic,
          attempts: this.reconnectAttempt,
        },
        true
      );
      return;
    }

    this.reconnectAttempt += 1;
    const delay = Math.min(
      1000 * 2 ** this.reconnectAttempt,
      RECONNECT_MAX_DELAY_MS
    );

    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this.startSSE();
    }, delay);
  };

  // ----------------------------------------------------------
  // MANUAL RECONNECT (UI butonu)
  // ----------------------------------------------------------
  manualReconnect = () => {
    if (this.isUnmounted) return;
    this.reconnectAttempt = 0;
    this.lastErrorLogTs = 0;
    this.startSSE();
  };

  // ----------------------------------------------------------
  // FLUSH BUFFER → STATE (batched)
  // ----------------------------------------------------------
  scheduleFlush = () => {
    if (this.flushTimer) return;
    if (this.isUnmounted) return;

    this.flushTimer = setTimeout(() => {
      this.flushTimer = null;
      if (this.isUnmounted) return;
      if (this.sseBuffer.length === 0) return;

      const batch = this.sseBuffer.splice(0, this.sseBuffer.length);
      this.safeSetState((prev) => ({
        notifications: [...batch, ...prev.notifications],
      }));
    }, FLUSH_INTERVAL_MS);
  };

  // ----------------------------------------------------------
  // RENDER
  // ----------------------------------------------------------
  render() {
    const { connection, notifications } = this.state;
    const { status, attempt, error } = connection;

    return (
      <div className="notification-subscriber">
        <div className="status-bar">
          <span className={`status status-${status}`}>{status}</span>

          {status === 'connecting' && attempt > 0 && (
            <small>
              Yeniden deneniyor… ({attempt}/{MAX_RECONNECT_ATTEMPTS})
            </small>
          )}

          {status === 'error' && error && (
            <small>
              readyState={error.readyState} · online=
              {String(error.online)}
              {error.connectionDurationMs != null && (
                <> · bağlı kaldı: {Math.round(error.connectionDurationMs / 1000)}s</>
              )}
            </small>
          )}

          {status === 'failed' && (
            <div className="failed-banner">
              <strong>Bağlantı kurulamadı</strong>
              <span>
                {MAX_RECONNECT_ATTEMPTS} deneme başarısız oldu.
              </span>
              <button onClick={this.manualReconnect} type="button">
                Yeniden bağlan
              </button>
            </div>
          )}
        </div>

        <ul className="notifications">
          {notifications.map((n) => (
            <li key={n.id}>
              {n.title && <strong>{n.title}</strong>}
              <span>{n.message}</span>
            </li>
          ))}
        </ul>
      </div>
    );
  }
}

export default NotificationSubscriber;
