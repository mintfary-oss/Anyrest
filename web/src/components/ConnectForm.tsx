import React, { useState } from 'react';

interface ConnectFormProps {
  myId: string | null;
  onConnect: (targetId: string) => void;
  disabled?: boolean;
}

export const ConnectForm: React.FC<ConnectFormProps> = ({ myId, onConnect, disabled }) => {
  const [targetId, setTargetId] = useState('');

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    const id = targetId.replace(/\D/g, '');
    if (id.length === 9) onConnect(id);
  };

  const formatId = (raw: string) => {
    const digits = raw.replace(/\D/g, '').slice(0, 9);
    // Format as XXX XXX XXX
    return digits.replace(/(\d{3})(\d{1,3})?(\d{1,3})?/, (_, a, b, c) =>
      [a, b, c].filter(Boolean).join(' '),
    );
  };

  return (
    <div className="connect-form">
      <div className="my-id-section">
        <span className="label">Your ID</span>
        <span className="id-display">{myId ? formatId(myId) : '— — —'}</span>
        {myId && (
          <button
            className="copy-btn"
            onClick={() => navigator.clipboard.writeText(myId)}
            title="Copy ID"
          >
            Copy
          </button>
        )}
      </div>

      <div className="divider" />

      <form onSubmit={handleSubmit} className="target-section">
        <span className="label">Remote ID</span>
        <input
          type="text"
          inputMode="numeric"
          placeholder="000 000 000"
          value={formatId(targetId)}
          onChange={(e) => setTargetId(e.target.value.replace(/\D/g, ''))}
          disabled={disabled}
          maxLength={11}
          className="id-input"
          autoComplete="off"
        />
        <button
          type="submit"
          disabled={disabled || targetId.replace(/\D/g, '').length !== 9}
          className="connect-btn"
        >
          Connect
        </button>
      </form>
    </div>
  );
};
