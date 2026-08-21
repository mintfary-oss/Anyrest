import React from 'react';
import type { DiagStats } from '../lib/webrtc';
import type { ViewerState } from '../lib/webrtc';

interface DiagnosticsPanelProps {
  stats: DiagStats;
  viewerState: ViewerState;
  signalingOk: boolean;
  frameCount: number;
  onClose: () => void;
}

/** Human-readable label for RTCPeerConnectionState */
const PC_STATE_LABEL: Record<RTCPeerConnectionState | 'none', string> = {
  none:         'Нет соединения',
  new:          'Инициализация',
  connecting:   'Подключение…',
  connected:    'Подключено',
  disconnected: 'Разорвано',
  failed:       'Ошибка',
  closed:       'Закрыто',
};

/** CSS class suffix for each state */
const PC_STATE_CLS: Record<RTCPeerConnectionState | 'none', string> = {
  none:         'muted',
  new:          'warn',
  connecting:   'warn',
  connected:    'ok',
  disconnected: 'err',
  failed:       'err',
  closed:       'muted',
};

interface RowProps { label: string; value: React.ReactNode; cls?: string }
const Row: React.FC<RowProps> = ({ label, value, cls }) => (
  <tr>
    <td className="diag-label">{label}</td>
    <td className={`diag-value ${cls ?? ''}`}>{value}</td>
  </tr>
);

const fmtBytes = (b: number) => {
  if (b < 1024) return `${b} B`;
  if (b < 1024 * 1024) return `${(b / 1024).toFixed(1)} KB`;
  return `${(b / (1024 * 1024)).toFixed(2)} MB`;
};

const fmtId = (id: string) =>
  id.replace(/(\d{3})(\d{3})(\d{3})/, '$1 $2 $3') || '—';

/**
 * Diagnostics panel — shows live connection stats and explains what
 * "connected" means in plain language.
 */
export const DiagnosticsPanel: React.FC<DiagnosticsPanelProps> = ({
  stats,
  viewerState,
  signalingOk,
  frameCount,
  onClose,
}) => {
  const isConnected = viewerState === 'connected';

  // Quality rating based on RTT
  const quality = (() => {
    if (!isConnected) return null;
    if (stats.rttMs < 0) return { label: 'Измеряется…', cls: 'warn' };
    if (stats.rttMs < 50)  return { label: 'Отлично', cls: 'ok' };
    if (stats.rttMs < 120) return { label: 'Хорошо', cls: 'ok' };
    if (stats.rttMs < 250) return { label: 'Удовлетворительно', cls: 'warn' };
    return { label: 'Плохо', cls: 'err' };
  })();

  const pcCls = PC_STATE_CLS[stats.pcState];

  return (
    <div className="diag-overlay" onClick={(e) => { if (e.target === e.currentTarget) onClose(); }}>
      <div className="diag-panel">

        {/* ── Header ───────────────────────────────────────────────────── */}
        <div className="diag-header">
          <div className="diag-title">
            <svg width="16" height="16" viewBox="0 0 16 16" fill="none" style={{flexShrink:0}}>
              <circle cx="8" cy="8" r="7" stroke="currentColor" strokeWidth="1.5"/>
              <path d="M8 5v3l2 2" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round"/>
            </svg>
            Диагностика соединения
          </div>
          <button className="diag-close" onClick={onClose}>✕</button>
        </div>

        <div className="diag-body">

          {/* ── Status summary ──────────────────────────────────────────── */}
          <div className={`diag-summary ${isConnected ? 'diag-summary-ok' : 'diag-summary-idle'}`}>
            {isConnected ? (
              <>
                <div className="diag-summary-icon">✓</div>
                <div>
                  <div className="diag-summary-title">Сеанс активен</div>
                  <div className="diag-summary-sub">
                    Вы видите рабочий стол удалённого ПК и можете управлять им
                    мышью и клавиатурой — как в AnyDesk.
                    {stats.rttMs >= 0 && ` Задержка ${stats.rttMs} мс.`}
                  </div>
                </div>
              </>
            ) : viewerState === 'connecting' ? (
              <>
                <div className="diag-summary-icon spin">↻</div>
                <div>
                  <div className="diag-summary-title">Подключаемся…</div>
                  <div className="diag-summary-sub">
                    Идёт WebRTC-согласование с агентом. Обычно занимает 2–5 сек.
                  </div>
                </div>
              </>
            ) : (
              <>
                <div className="diag-summary-icon err">!</div>
                <div>
                  <div className="diag-summary-title">Нет активного сеанса</div>
                  <div className="diag-summary-sub">
                    Введите 9-значный ID агента и нажмите Connect.
                  </div>
                </div>
              </>
            )}
          </div>

          {/* ── Two-column layout ───────────────────────────────────────── */}
          <div className="diag-cols">

            {/* Left column — connection */}
            <div className="diag-section">
              <div className="diag-section-title">Подключение</div>
              <table className="diag-table">
                <tbody>
                  <Row label="Сигнальный сервер"
                       value={signalingOk ? 'Подключён' : 'Нет связи'}
                       cls={signalingOk ? 'ok' : 'err'} />
                  <Row label="WebRTC статус"
                       value={PC_STATE_LABEL[stats.pcState]}
                       cls={pcCls} />
                  <Row label="ICE состояние"
                       value={stats.iceState === 'none' ? '—' : stats.iceState}
                       cls={stats.iceState === 'connected' || stats.iceState === 'completed'
                            ? 'ok' : 'muted'} />
                  <Row label="Канал данных"
                       value={stats.dcState === 'none' ? '—' : stats.dcState}
                       cls={stats.dcState === 'open' ? 'ok' : 'muted'} />
                  <Row label="Тип соединения"
                       value={stats.connectionType}
                       cls={stats.candidateType === 'host' ? 'ok'
                            : stats.candidateType === 'relay' ? 'warn' : 'muted'} />
                  <Row label="ID удалённого агента"
                       value={fmtId(stats.remotePeerId)} />
                </tbody>
              </table>
            </div>

            {/* Right column — stream quality */}
            <div className="diag-section">
              <div className="diag-section-title">Качество потока</div>
              <table className="diag-table">
                <tbody>
                  {quality && (
                    <Row label="Качество"
                         value={quality.label}
                         cls={quality.cls} />
                  )}
                  <Row label="Задержка (RTT)"
                       value={stats.rttMs >= 0 ? `${stats.rttMs} мс` : isConnected ? 'Измеряется…' : '—'}
                       cls={stats.rttMs >= 0 && stats.rttMs < 120 ? 'ok'
                            : stats.rttMs >= 120 ? 'warn' : 'muted'} />
                  <Row label="Кадров в секунду"
                       value={isConnected ? `${stats.fps} fps` : '—'}
                       cls={stats.fps > 5 ? 'ok' : isConnected ? 'warn' : 'muted'} />
                  <Row label="Всего кадров"
                       value={isConnected ? frameCount.toLocaleString() : '—'} />
                  <Row label="Скорость потока"
                       value={isConnected ? `${stats.bandwidthKBps} KB/s` : '—'} />
                  <Row label="Получено данных"
                       value={isConnected ? fmtBytes(stats.bytesReceived) : '—'} />
                </tbody>
              </table>
            </div>

          </div>

          {/* ── How it works ────────────────────────────────────────────── */}
          <div className="diag-explainer">
            <div className="diag-explainer-title">Как это работает</div>
            <div className="diag-explainer-rows">
              <div className="diag-exp-row">
                <span className="diag-exp-icon ok">✓</span>
                <span>
                  <strong>Рабочий стол агента</strong> захватывается как JPEG-кадры
                  (15 fps) и передаётся по зашифрованному WebRTC DataChannel напрямую
                  в ваш браузер.
                </span>
              </div>
              <div className="diag-exp-row">
                <span className="diag-exp-icon ok">✓</span>
                <span>
                  <strong>Мышь и клавиатура</strong> — ваши действия на canvas
                  отправляются агенту и инжектируются через системный API
                  (xdotool на Linux, Win32 SendInput на Windows).
                </span>
              </div>
              <div className="diag-exp-row">
                <span className={`diag-exp-icon ${stats.candidateType === 'relay' ? 'warn' : 'ok'}`}>
                  {stats.candidateType === 'relay' ? '!' : '✓'}
                </span>
                <span>
                  <strong>Шифрование</strong>: DTLS 1.3 + AES-256-GCM.
                  {stats.candidateType === 'host'
                    ? ' Соединение прямое — нет облака, нет посредников.'
                    : stats.candidateType === 'relay'
                    ? ' Идёт через relay-сервер (NAT блокирует прямое P2P).'
                    : ' Соединение защищено сквозным шифрованием.'}
                </span>
              </div>
            </div>
          </div>

          {/* ── Server info ──────────────────────────────────────────────── */}
          {stats.signalUrl && (
            <div className="diag-server-info">
              Сигнальный сервер: <code>{stats.signalUrl}</code>
            </div>
          )}

        </div>
      </div>
    </div>
  );
};
