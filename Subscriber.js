import React from 'react';
import { sendConnectionLog } from './api/connectionLog';
import { mapNtfyToNotification } from './utils/ntfyMapper';

const MAX_RECONNECT_ATTEMPTS = 3;
const FLUSH_INTERVAL_MS = 200;
const LOG_THROTTLE_MS = 10000;

// === ntfy error code katalogu ===
const NTFY_PERMANENT_CODES = new Set([
  40101, // unauthorized
  40301, // forbidden (ACL)
  40401, // page not found
  40009, // invalid topic
  40010, // topic disallowed
  40008, // invalid since
]);

const NTFY_TRANSIENT_CODES = new Set([
  42901, // rate limit: too many requests
  42903, // too many active subscriptions
  42909, // too many auth failures
  50001, 50002, 50003, 50004, // 5xx
]);

const NTFY_CODE_MESSAGES = {
  40008: 'Geçersiz since parametresi',
  40009: 'Geçersiz topic adı',
  40010: 'Topic adına izin verilmiyor',
  40101: 'Yetkilendirme gerekli (token/credentials)',
  40301: 'Topic için erişim yetkisi yok (ACL)',
  40401: 'Endpoint bulunamadı',
  42901: 'Rate limit aşıldı',
  42903: 'Aktif subscription limiti aşıldı',
  42909: 'Çok fazla auth hatası — geçici blok',
  50001: 'ntfy sunucu hatası',
  50003: 'ntfy sunucusunda base-url eksik',
};

class NotificationSubscriber extends React.Component {
  state = {
    resolvedTopic: this.props.topic || null,
    connection: {
      status: 'idle',
      topic: null,
      error: null,
      attempt: 0,
      ts: null,
    },
    notifications: [],
  };

  esRef = null;
  sseBuffer = [];
  flushTimer = null;
  reconnectTimer = null;
  reconnectAttempt = 0;
  lastErrorLogTs = 0;
  errorLogInFlight = false;
  isStopped = false;
  preflightAbort = null;

  // ============================================================
  // LIFECYCLE
  // ============================================================
  componentDidMount() {
    this.isStopped = false;
    if (this.state.resolvedTopic) this.startSSE();
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
    this.isStopped = true;
    this.stopSSE();
    if (this.flushTimer) {
      clearTimeout(this.flushTimer);
      this.flushTimer = null;
    }
  }

  // ============================================================
  // URL BUILDERS
  // ============================================================
  getBaseUrl = () => {
    const { hostname, protocol } = window.location;
    const isLocal =
      hostname === 'localhost' ||
      hostname === '127.0.0.1' ||
      hostname.startsWith('192.168.') ||
      hostname.endsWith('.local');
    return isLocal
      ? 'http://localhost:9393'
      : `${protocol}//${hostname}`;
  };

  buildSseUrl = (topic) => `${this.getBaseUrl()}/${topic}/sse`;
  buildPreflightUrl = (topic) =>
    `${this.getBaseUrl()}/${topic}/json?poll=1&since=1s`;

  // ============================================================
  // CONNECTION LOG
  // ============================================================
  safeSendConnectionLog = (statusCode, message, meta = {}, force = false) => {
    const now = Date.now();
    if (!force && now - this.lastErrorLogTs < LOG_THROTTLE_MS) return;
    if (this.errorLogInFlight && !force) return;

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
  // PREFLIGHT — ntfy'nin gerçek error kodunu al
  // ============================================================
  preflightCheck = async (topic) => {
    this.preflightAbort = new AbortController();
    const url = this.buildPreflightUrl(topic);

    try {
      const res = await fetch(url, {
        signal: this.preflightAbort.signal,
        // Auth gerekirse:
        // headers: { Authorization: `Bearer ${this.props.authToken}` },
      });

      if (res.ok) {
        return { ok: true };
      }

      // ntfy 4xx/5xx body'sini parse et
      let ntfyError = null;
      try {
        ntfyError = await res.json();
      } catch (_) {
        // Body JSON değil (proxy hatası vs.)
      }

      const code = ntfyError?.code;
      const isPermanent = code && NTFY_PERMANENT_CODES.has(code);
      const isTransient = code && NTFY_TRANSIENT_CODES.has(code);

      return {
        ok: false,
        httpStatus: res.status,
        ntfyCode: code,
        ntfyError: ntfyError?.error,
        ntfyLink: ntfyError?.link,
        isPermanent,
        isTransient,
        friendlyMessage:
          (code && NTFY_CODE_MESSAGES[code]) ||
          ntfyError?.error ||
          `HTTP ${res.status}`,
      };
    } catch (netErr) {
      if (netErr.name === 'AbortError') {
        return { ok: false, aborted: true };
      }
      return {
        ok: false,
        networkError: true,
        errorMessage: netErr.message,
        friendlyMessage: 'Ağ hatası — ntfy sunucusuna ulaşılamıyor',
      };
    } finally {
      this.preflightAbort = null;
    }
  };

  // ============================================================
  // STOP
  // ============================================================
  stopSSE = () => {
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    if (this.preflightAbort) {
      try { this.preflightAbort.abort(); } catch (_) {}
      this.preflightAbort = null;
    }
    if (this.esRef) {
      try {
        this.esRef.onopen = null;
        this.esRef.onmessage = null;
        this.esRef.onerror = null;
        this.esRef.close();
      } catch (_) {}
      this.esRef = null;
    }
  };

  // ============================================================
  // START
  // ============================================================
  startSSE = async () => {
    this.stopSSE();
    if (this.isStopped) return;

    const { resolvedTopic } = this.state;
    if (!resolvedTopic) return;

    this.setState({
      connection: {
        status: 'connecting',
        topic: resolvedTopic,
        error: null,
        attempt: this.reconnectAttempt,
        ts: Date.now(),
      },
    });

    // === 1) PREFLIGHT: ntfy gerçek hata kodunu al ===
    const preflight = await this.preflightCheck(resolvedTopic);
    if (this.isStopped) return;
    if (preflight.aborted) return;

    if (!preflight.ok) {
      // Hatayı detaylı logla
      this.safeSendConnectionLog(
        String(preflight.httpStatus || 599),
        `ntfy preflight failed: ${preflight.friendlyMessage}`,
        {
          topic: resolvedTopic,
          httpStatus: preflight.httpStatus,
          ntfyCode: preflight.ntfyCode,
          ntfyError: preflight.ntfyError,
          isPermanent: preflight.isPermanent,
          isTransient: preflight.isTransient,
          online: navigator.onLine,
        },
        true // force log (permanent errors throttle'a takılmasın)
      );

      // Kalıcı hata → retry yapma, failed state'e geç
      if (preflight.isPermanent) {
        this.setState({
          connection: {
            status: 'failed',
            topic: resolvedTopic,
            error: {
              reason: 'permanent_ntfy_error',
              ntfyCode: preflight.ntfyCode,
              message: preflight.friendlyMessage,
              link: preflight.ntfyLink,
            },
            attempt: this.reconnectAttempt,
            ts: Date.now(),
          },
        });
        return;
      }

      // Geçici hata veya network → backoff retry
      this.setState({
        connection: {
          status: 'error',
          topic: resolvedTopic,
          error: {
            ntfyCode: preflight.ntfyCode,
            message: preflight.friendlyMessage,
            httpStatus: preflight.httpStatus,
          },
          attempt: this.reconnectAttempt,
          ts: Date.now(),
        },
      });
      this.scheduleReconnect();
      return;
    }

    // === 2) Preflight OK → EventSource aç ===
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

    es.onopen = () => {
      if (es !== this.esRef) return;
      this.reconnectAttempt = 0;
      this.lastErrorLogTs = 0;
      this.setState({
        connection: {
          status: 'connected',
          topic: resolvedTopic,
          error: null,
          attempt: 0,
          ts: Date.now(),
        },
      });
      this.safeSendConnectionLog('200', 'SSE bağlantısı başarılı', {
        topic: resolvedTopic,
      });
    };

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

    es.onerror = () => {
      if (es !== this.esRef) return;
      const readyState = es.readyState;

      this.setState({
        connection: {
          status: 'error',
          topic: resolvedTopic,
          error: { readyState, online: navigator.onLine },
          attempt: this.reconnectAttempt,
          ts: Date.now(),
        },
      });

      this.safeSendConnectionLog(
        '502',
        `SSE bağlantı koptu (readyState=${readyState})`,
        { topic: resolvedTopic, readyState, online: navigator.onLine }
      );

      // Stream sırasında bağlantı koptu → tekrar dene (preflight'tan başla)
      if (readyState === EventSource.CLOSED) {
        this.stopSSE();
        this.scheduleReconnect();
      }
    };
  };

  // ============================================================
  // RECONNECT (capped)
  // ============================================================
  scheduleReconnect = () => {
    if (this.isStopped) return;
    if (this.reconnectTimer) return;

    if (this.reconnectAttempt >= MAX_RECONNECT_ATTEMPTS) {
      this.setState({
        connection: {
          status: 'failed',
          topic: this.state.resolvedTopic,
          error: { reason: 'max_attempts_reached' },
          attempt: this.reconnectAttempt,
          ts: Date.now(),
        },
      });
      this.safeSendConnectionLog(
        '503',
        `SSE giving up after ${MAX_RECONNECT_ATTEMPTS} attempts`,
        { topic: this.state.resolvedTopic, attempts: this.reconnectAttempt },
        true
      );
      return;
    }

    this.reconnectAttempt += 1;
    const delay = Math.min(1000 * 2 ** this.reconnectAttempt, 30000);
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this.startSSE();
    }, delay);
  };

  manualReconnect = () => {
    this.reconnectAttempt = 0;
    this.lastErrorLogTs = 0;
    this.startSSE();
  };

  // ============================================================
  // FLUSH
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
    }, FLUSH_INTERVAL_MS);
  };

  // ============================================================
  // RENDER
  // ============================================================
  render() {
    const { connection, notifications } = this.state;
    const { status, attempt, error } = connection;

    return (
      <div className="notification-subscriber">
        <div className="status-bar">
          <span className={`status status-${status}`}>{status}</span>

          {status === 'connecting' && attempt > 0 && (
            <small>Yeniden deneniyor… ({attempt}/{MAX_RECONNECT_ATTEMPTS})</small>
          )}

          {status === 'error' && error?.ntfyCode && (
            <small>
              ntfy-{error.ntfyCode}: {error.message}
            </small>
          )}

          {status === 'failed' && (
            <div className="failed-banner">
              <strong>Bağlantı başarısız</strong>
              {error?.ntfyCode && (
                <div>
                  Hata kodu: <code>{error.ntfyCode}</code> — {error.message}
                  {error.link && (
                    <a href={error.link} target="_blank" rel="noreferrer">
                      Detay
                    </a>
                  )}
                </div>
              )}
              {error?.reason === 'max_attempts_reached' && (
                <div>
                  {MAX_RECONNECT_ATTEMPTS} deneme başarısız oldu.
                </div>
              )}
              <button onClick={this.manualReconnect} type="button">
                Yeniden bağlan
              </button>
            </div>
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
