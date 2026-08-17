import React, { useEffect, useRef, useState, useCallback } from 'react';
import { SignalingClient } from './lib/signaling';
import { WebRTCViewer } from './lib/webrtc';
import type { ViewerState } from './lib/webrtc';
import type { InputEvent } from './lib/protocol';
import { ConnectForm } from './components/ConnectForm';
import { RemoteScreen } from './components/RemoteScreen';
import { StatusBar } from './components/StatusBar';
import { HelpPage } from './components/HelpPage';

const SIGNAL_URL =
  (window as Window & { ANYREST_SIGNAL_URL?: string }).ANYREST_SIGNAL_URL ??
  `wss://${window.location.host}/ws`;

export const App: React.FC = () => {
  const [signalingOk, setSignalingOk] = useState(false);
  const [myId, setMyId] = useState<string | null>(null);
  const [viewerState, setViewerState] = useState<ViewerState>('idle');
  const [frameUrl, setFrameUrl] = useState<string | null>(null);
  const [remotePeerId, setRemotePeerId] = useState<string | null>(null);
  const [showHelp, setShowHelp] = useState(false);

  const signalingRef = useRef<SignalingClient | null>(null);
  const viewerRef = useRef<WebRTCViewer | null>(null);

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
      (state) => {
        setViewerState(state);
        if (state === 'disconnected' || state === 'failed') {
          setFrameUrl(null);
          setRemotePeerId(null);
        }
      },
      (url) => setFrameUrl(url),
    );
    viewerRef.current = viewer;

    sig.connect().catch(console.error);
    return () => { sig.disconnect(); };
  }, []);

  // Close help on Escape
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (e.key === 'Escape') setShowHelp(false);
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
  }, []);

  const handleInput = useCallback((event: InputEvent) => {
    viewerRef.current?.sendInput(event);
  }, []);

  // ── Render ────────────────────────────────────────────────────────────────

  const isConnected = viewerState === 'connected';
  const serverHost = window.location.host || 'localhost';

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
        <button
          className="help-btn"
          onClick={() => setShowHelp(true)}
          title="Руководство пользователя"
        >
          ?
        </button>
      </header>

      <main className="app-main">
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

        <RemoteScreen
          frameUrl={frameUrl}
          onInput={handleInput}
          active={isConnected}
        />
      </main>

      {showHelp && (
        <HelpPage
          onClose={() => setShowHelp(false)}
          serverHost={serverHost}
        />
      )}
    </div>
  );
};
