import React, { useEffect, useRef, useState, useCallback } from 'react';
import { SignalingClient } from './lib/signaling';
import { WebRTCViewer } from './lib/webrtc';
import type { ViewerState, DiagStats } from './lib/webrtc';
import type { InputEvent } from './lib/protocol';
import { ConnectForm } from './components/ConnectForm';
import { RemoteScreen } from './components/RemoteScreen';
import { StatusBar } from './components/StatusBar';
import { HelpPage } from './components/HelpPage';
import { ConnectedToolbar } from './components/ConnectedToolbar';
import { DiagnosticsPanel } from './components/DiagnosticsPanel';

const SIGNAL_URL =
  (window as Window & { ANYREST_SIGNAL_URL?: string }).ANYREST_SIGNAL_URL ??
  `wss://${window.location.host}/ws`;

export const App: React.FC = () => {
  const [signalingOk, setSignalingOk]     = useState(false);
  const [myId, setMyId]                   = useState<string | null>(null);
  const [viewerState, setViewerState]     = useState<ViewerState>('idle');
  const [frameUrl, setFrameUrl]           = useState<string | null>(null);
  const [remotePeerId, setRemotePeerId]   = useState<string | null>(null);
  const [showHelp, setShowHelp]           = useState(false);
  const [showDiag, setShowDiag]           = useState(false);
  const [diagStats, setDiagStats]         = useState<DiagStats | null>(null);
  const [frameCount, setFrameCount]       = useState(0);

  const signalingRef = useRef<SignalingClient | null>(null);
  const viewerRef    = useRef<WebRTCViewer | null>(null);
  const frameCountRef = useRef(0);

  // ── Boot ─────────────────────────────────────────────────────────────────

  useEffect(() => {
    const sig = new SignalingClient(SIGNAL_URL);
    signalingRef.current = sig;

    sig.addEventListener('open', () => {
      setSignalingOk(true);
      sig.register();
    });
    sig.addEventListener('close', () => setSignalingOk(false));
    sig.addEventListener('registered', ((ev: CustomEvent) => {
      setMyId((ev.detail as { peer_id: string }).peer_id);
    }) as EventListener);

    const viewer = new WebRTCViewer(
      sig,
      // State change handler
      (state) => {
        setViewerState(state);
        if (state === 'disconnected' || state === 'failed') {
          setFrameUrl(null);
          setRemotePeerId(null);
          setDiagStats(null);
          setFrameCount(0);
          frameCountRef.current = 0;
          setShowDiag(false);
        }
      },
      // Frame handler — also tracks frame count
      (url) => {
        setFrameUrl(url);
        frameCountRef.current += 1;
        setFrameCount(frameCountRef.current);
      },
      // Stats handler
      (stats) => setDiagStats(stats),
      SIGNAL_URL,
    );
    viewerRef.current = viewer;

    sig.connect().catch(console.error);
    return () => { sig.disconnect(); };
  }, []);

  // Close help/diag on Escape
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        setShowHelp(false);
        setShowDiag(false);
      }
    };
    window.addEventListener('keydown', handler);
    return () => window.removeEventListener('keydown', handler);
  }, []);

  // ── Handlers ──────────────────────────────────────────────────────────────

  const handleConnect = useCallback((targetId: string) => {
    setRemotePeerId(targetId);
    viewerRef.current?.startSession(targetId);
  }, []);

  const handleDisconnect = useCallback(() => {
    viewerRef.current?.close();
    setRemotePeerId(null);
    setFrameUrl(null);
    setViewerState('idle');
    setDiagStats(null);
    setFrameCount(0);
    frameCountRef.current = 0;
    setShowDiag(false);
  }, []);

  const handleInput = useCallback((event: InputEvent) => {
    viewerRef.current?.sendInput(event);
  }, []);

  const handleToggleDiag = useCallback(() => {
    setShowDiag((v) => !v);
    setShowHelp(false);
  }, []);

  // ── Render ────────────────────────────────────────────────────────────────

  const isConnected  = viewerState === 'connected';
  const serverHost   = window.location.host || 'localhost';

  // Stats to show in the panel: live stats or a skeleton while connecting
  const panelStats: DiagStats = diagStats ?? {
    pcState: viewerState === 'connecting' ? 'connecting' : 'none',
    iceState: 'none',
    dcState: 'none',
    candidateType: 'unknown',
    rttMs: -1,
    fps: 0,
    bytesReceived: 0,
    bandwidthKBps: 0,
    remotePeerId: remotePeerId ?? '',
    signalUrl: SIGNAL_URL,
    connectionType: 'Нет подключения',
  };

  return (
    <div className="app">
      <header className="app-header">
        <div className="logo">
          <span className="logo-icon">⬡</span>
          <span className="logo-text">Anyrest</span>
        </div>

        <StatusBar
          signalingConnected={signalingOk}
          viewerState={viewerState}
          remotePeerId={remotePeerId}
          onDisconnect={handleDisconnect}
        />

        {/* Diagnostics button — always visible */}
        <button
          className={`toolbar-btn header-diag-btn${showDiag ? ' active' : ''}`}
          onClick={handleToggleDiag}
          title="Диагностика соединения"
        >
          <svg width="13" height="13" viewBox="0 0 16 16" fill="none">
            <circle cx="8" cy="8" r="7" stroke="currentColor" strokeWidth="1.5"/>
            <path d="M8 5v3l2 2" stroke="currentColor" strokeWidth="1.5"
                  strokeLinecap="round"/>
          </svg>
          Диагностика
        </button>

        <button
          className="help-btn"
          onClick={() => { setShowHelp(true); setShowDiag(false); }}
          title="Руководство пользователя"
        >
          ?
        </button>
      </header>

      <main className="app-main">
        {/* Sidebar — shown only when not in a session */}
        {!isConnected && (
          <div className="sidebar">
            <ConnectForm
              myId={myId}
              onConnect={handleConnect}
              disabled={!signalingOk || viewerState === 'connecting'}
            />
            <div className="info-box">
              <h3>Как подключиться</h3>
              <ol>
                <li>Установите агент на удалённый ПК.</li>
                <li>Введите 9-значный ID агента.</li>
                <li>Нажмите <strong>Connect</strong>.</li>
              </ol>
              <button
                className="connect-btn"
                style={{ marginTop: 4 }}
                onClick={() => setShowHelp(true)}
              >
                Подробное руководство
              </button>
              <p className="security-note">
                Сквозное шифрование DTLS 1.3 + AES-256-GCM. Без облака.
              </p>
            </div>
          </div>
        )}

        {/* Remote screen — fills remaining space */}
        <div className="remote-screen-wrap">
          <RemoteScreen
            frameUrl={frameUrl}
            onInput={handleInput}
            active={isConnected}
          />

          {/* Auto-hiding toolbar over the remote screen */}
          <ConnectedToolbar
            active={isConnected}
            remotePeerId={remotePeerId ?? ''}
            onDisconnect={handleDisconnect}
            onToggleDiag={handleToggleDiag}
            diagOpen={showDiag}
          />
        </div>
      </main>

      {/* Diagnostics overlay */}
      {showDiag && (
        <DiagnosticsPanel
          stats={panelStats}
          viewerState={viewerState}
          signalingOk={signalingOk}
          frameCount={frameCount}
          onClose={() => setShowDiag(false)}
        />
      )}

      {/* Help overlay */}
      {showHelp && (
        <HelpPage
          onClose={() => setShowHelp(false)}
          serverHost={serverHost}
        />
      )}
    </div>
  );
};
