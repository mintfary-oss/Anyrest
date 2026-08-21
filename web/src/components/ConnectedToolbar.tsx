import React, { useEffect, useRef, useState, useCallback } from 'react';

interface ConnectedToolbarProps {
  /** Whether we are actively in a remote session */
  active: boolean;
  /** Formatted peer ID of the remote host, e.g. "123 456 789" */
  remotePeerId: string;
  onDisconnect: () => void;
  onToggleDiag: () => void;
  diagOpen: boolean;
}

const HIDE_DELAY_MS = 3000;

/**
 * Auto-hiding overlay toolbar shown while connected to a remote agent.
 * Appears when the user moves the mouse; hides after HIDE_DELAY_MS of
 * inactivity. Always visible while the diagnostics panel is open.
 */
export const ConnectedToolbar: React.FC<ConnectedToolbarProps> = ({
  active,
  remotePeerId,
  onDisconnect,
  onToggleDiag,
  diagOpen,
}) => {
  const [visible, setVisible] = useState(true);
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const show = useCallback(() => {
    setVisible(true);
    if (timerRef.current) clearTimeout(timerRef.current);
    // Keep visible while diagnostics panel is open
    if (!diagOpen) {
      timerRef.current = setTimeout(() => setVisible(false), HIDE_DELAY_MS);
    }
  }, [diagOpen]);

  // When diagOpen changes, refresh visibility logic
  useEffect(() => {
    if (diagOpen) {
      // Keep toolbar visible while diag is open
      if (timerRef.current) clearTimeout(timerRef.current);
      setVisible(true);
    } else {
      // Start hide timer when diag closes
      timerRef.current = setTimeout(() => setVisible(false), HIDE_DELAY_MS);
    }
    return () => {
      if (timerRef.current) clearTimeout(timerRef.current);
    };
  }, [diagOpen]);

  // Listen to mouse moves on the whole window to re-show toolbar
  useEffect(() => {
    if (!active) return;
    const onMove = () => show();
    window.addEventListener('mousemove', onMove);
    return () => window.removeEventListener('mousemove', onMove);
  }, [active, show]);

  // Show on mount
  useEffect(() => {
    if (active) show();
  }, [active, show]);

  if (!active) return null;

  const formatted = remotePeerId.replace(/(\d{3})(\d{3})(\d{3})/, '$1 $2 $3');

  return (
    <div className={`connected-toolbar${visible ? ' visible' : ''}`}>
      {/* Remote ID badge */}
      <div className="toolbar-peer">
        <span className="toolbar-dot" />
        <span className="toolbar-peer-label">Подключено к</span>
        <span className="toolbar-peer-id">{formatted}</span>
      </div>

      <div className="toolbar-divider" />

      {/* Diagnostics toggle */}
      <button
        className={`toolbar-btn${diagOpen ? ' active' : ''}`}
        onClick={onToggleDiag}
        title="Диагностика соединения"
      >
        <svg width="14" height="14" viewBox="0 0 16 16" fill="none">
          <circle cx="8" cy="8" r="7" stroke="currentColor" strokeWidth="1.5"/>
          <path d="M5 8.5 L7 10.5 L11 6" stroke="currentColor" strokeWidth="1.5"
                strokeLinecap="round" strokeLinejoin="round"/>
        </svg>
        Диагностика
      </button>

      {/* Disconnect button */}
      <button
        className="toolbar-btn disconnect"
        onClick={onDisconnect}
        title="Завершить сеанс"
      >
        <svg width="14" height="14" viewBox="0 0 16 16" fill="none">
          <path d="M12 4L4 12M4 4l8 8" stroke="currentColor" strokeWidth="2"
                strokeLinecap="round"/>
        </svg>
        Завершить
      </button>
    </div>
  );
};
