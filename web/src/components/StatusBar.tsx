import React from 'react';
import type { ViewerState } from '../lib/webrtc';

interface StatusBarProps {
  signalingConnected: boolean;
  viewerState: ViewerState;
  remotePeerId: string | null;
  onDisconnect: () => void;
}

const STATE_LABELS: Record<ViewerState, string> = {
  idle: 'Ready',
  connecting: 'Connecting…',
  connected: 'Connected',
  failed: 'Connection failed',
  disconnected: 'Disconnected',
};

const STATE_CLASSES: Record<ViewerState, string> = {
  idle: 'idle',
  connecting: 'connecting',
  connected: 'connected',
  failed: 'failed',
  disconnected: 'idle',
};

export const StatusBar: React.FC<StatusBarProps> = ({
  signalingConnected,
  viewerState,
  remotePeerId,
  onDisconnect,
}) => (
  <div className="status-bar">
    <div className="status-left">
      <span className={`dot ${signalingConnected ? 'green' : 'red'}`} />
      <span className="status-text">
        {signalingConnected ? 'Server online' : 'Connecting to server…'}
      </span>
    </div>
    <div className="status-center">
      <span className={`state-badge ${STATE_CLASSES[viewerState]}`}>
        {STATE_LABELS[viewerState]}
      </span>
      {viewerState === 'connected' && remotePeerId && (
        <span className="remote-id">→ {remotePeerId.replace(/(\d{3})(\d{3})(\d{3})/, '$1 $2 $3')}</span>
      )}
    </div>
    <div className="status-right">
      {viewerState === 'connected' && (
        <button className="disconnect-btn" onClick={onDisconnect}>
          Disconnect
        </button>
      )}
    </div>
  </div>
);
