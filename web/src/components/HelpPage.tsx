import React from 'react';

interface HelpPageProps {
  onClose: () => void;
  serverHost: string;
}

/**
 * Full-screen help overlay with installation and usage instructions.
 * Shown when the user clicks the "?" button in the header.
 */
export const HelpPage: React.FC<HelpPageProps> = ({ onClose, serverHost }) => {
  const agentInstallCmd = `./install.sh --agent-only --signal-url wss://${serverHost}/ws`;
  const serverInstallCmd = `curl -fsSL https://raw.githubusercontent.com/mintfary-oss/Anyrest/main/install.sh | bash`;
  const dockerAgentCmd = `ANYREST_SIGNAL_URL=wss://${serverHost}/ws \\\n  docker compose -f docker-compose.agent.yml up -d`;

  return (
    <div className="help-overlay" role="dialog" aria-modal="true" aria-label="Help">
      <div className="help-panel">

        {/* Header */}
        <div className="help-header">
          <span className="help-title">Anyrest — Руководство пользователя</span>
          <button className="help-close" onClick={onClose} title="Закрыть">✕</button>
        </div>

        <div className="help-body">

          {/* TOC */}
          <nav className="help-toc">
            <a href="#quick-start">Быстрый старт</a>
            <a href="#install-agent">Установка агента</a>
            <a href="#connect">Подключение</a>
            <a href="#controls">Управление</a>
            <a href="#certificates">Сертификаты</a>
            <a href="#security">Безопасность</a>
            <a href="#troubleshooting">Устранение проблем</a>
          </nav>

          <div className="help-content">

            {/* ── Quick Start ── */}
            <section id="quick-start">
              <h2>Быстрый старт</h2>
              <p>
                Anyrest — это самостоятельно размещаемый аналог AnyDesk. Все данные
                передаются напрямую между устройствами и <strong>не проходят через
                облачные серверы</strong>.
              </p>

              <div className="help-steps">
                <div className="help-step">
                  <span className="step-num">1</span>
                  <div>
                    <strong>Установите сервер</strong> на центральную машину или VPS:
                    <pre><code>{serverInstallCmd}</code></pre>
                  </div>
                </div>
                <div className="help-step">
                  <span className="step-num">2</span>
                  <div>
                    <strong>Установите агент</strong> на каждый ПК, которым хотите управлять:
                    <pre><code>{agentInstallCmd}</code></pre>
                  </div>
                </div>
                <div className="help-step">
                  <span className="step-num">3</span>
                  <div>
                    <strong>Откройте веб-интерфейс</strong> в браузере:
                    <pre><code>https://{serverHost}</code></pre>
                    Введите 9-значный ID агента и нажмите <strong>Connect</strong>.
                  </div>
                </div>
              </div>
            </section>

            {/* ── Install Agent ── */}
            <section id="install-agent">
              <h2>Установка агента</h2>
              <p>Агент запускается на том ПК, <em>которым вы хотите управлять</em>.</p>

              <h3>Вариант 1 — Docker (рекомендуется)</h3>
              <pre><code>{dockerAgentCmd}</code></pre>
              <p>Агент автоматически стартует при перезагрузке.</p>

              <h3>Вариант 2 — Скрипт установки</h3>
              <pre><code>{agentInstallCmd}</code></pre>
              <p>
                Скрипт установит Docker (если отсутствует), создаст systemd-сервис
                и запустит агент. Поддерживаемые ОС: Ubuntu, Debian, RHEL, CentOS,
                Fedora, Alpine, macOS.
              </p>

              <h3>Флаги агента</h3>
              <table className="help-table">
                <thead>
                  <tr><th>Флаг</th><th>По умолчанию</th><th>Описание</th></tr>
                </thead>
                <tbody>
                  <tr><td><code>-signal</code></td><td><code>ws://localhost:8080/ws</code></td><td>URL сигнального сервера</td></tr>
                  <tr><td><code>-fps</code></td><td><code>15</code></td><td>Частота кадров (1–30)</td></tr>
                  <tr><td><code>-quality</code></td><td><code>75</code></td><td>Качество JPEG (1–100)</td></tr>
                  <tr><td><code>-display</code></td><td><code>0</code></td><td>Индекс монитора</td></tr>
                  <tr><td><code>-x-display</code></td><td><code>:0</code></td><td>X11 DISPLAY (Linux)</td></tr>
                </tbody>
              </table>

              <div className="help-note">
                <strong>Linux:</strong> агенту нужен запущенный X-сервер (Xorg или Xwayland)
                и установленный <code>xdotool</code> для инъекции ввода.
              </div>
            </section>

            {/* ── Connect ── */}
            <section id="connect">
              <h2>Подключение к удалённому ПК</h2>

              <ol className="help-numbered">
                <li>
                  Откройте <strong>https://{serverHost}</strong> в браузере.
                </li>
                <li>
                  В поле <strong>Your ID</strong> отображается ваш собственный ID
                  (если этот браузер тоже может принимать соединения через агент).
                </li>
                <li>
                  В поле <strong>Remote ID</strong> введите 9-значный ID
                  удалённого агента. Агент показывает ID в логе при старте:
                  <pre><code>[anyrest] registered — ID: 123456789</code></pre>
                </li>
                <li>Нажмите <strong>Connect</strong>.</li>
                <li>
                  После установки соединения экран удалённого ПК появится
                  в правой части окна. Кнопка <strong>Disconnect</strong>
                  разрывает сессию.
                </li>
              </ol>

              <div className="help-note info">
                Если прямое P2P-соединение невозможно (NAT/файрволл), трафик
                автоматически перенаправляется через relay-сервер. Шифрование
                сохраняется в обоих случаях.
              </div>
            </section>

            {/* ── Controls ── */}
            <section id="controls">
              <h2>Управление во время сессии</h2>

              <table className="help-table">
                <thead>
                  <tr><th>Действие</th><th>Как выполнить</th></tr>
                </thead>
                <tbody>
                  <tr><td>Перемещение мыши</td><td>Двигайте курсор в области экрана</td></tr>
                  <tr><td>Клик мышью</td><td>ЛКМ / ПКМ / СКМ как обычно</td></tr>
                  <tr><td>Прокрутка</td><td>Колесо мыши</td></tr>
                  <tr><td>Ввод текста</td><td>Просто печатайте (фокус на экране)</td></tr>
                  <tr><td>Горячие клавиши</td><td>Все клавиши передаются на удалённый ПК</td></tr>
                  <tr><td>Отключиться</td><td>Кнопка <strong>Disconnect</strong> в шапке</td></tr>
                </tbody>
              </table>

              <div className="help-note warn">
                <strong>Исключения:</strong> <code>Ctrl+R</code>, <code>Ctrl+L</code>,
                <code>Ctrl+W</code>, <code>Ctrl+T</code> — не передаются (браузер
                перехватывает эти комбинации).
              </div>
            </section>

            {/* ── Certificates ── */}
            <section id="certificates">
              <h2>Сертификаты — как добавить доверие браузеру</h2>
              <p>
                Anyrest использует самоподписной сертификат с IP-адресом (IP-SAN).
                Чтобы браузер доверял ему без предупреждений, нужно установить
                корневой CA-сертификат.
              </p>

              <div className="help-note info">
                Если вы запускали <code>install.sh</code>, CA уже установлен
                автоматически — перезапустите браузер.
              </div>

              <h3>Ручная установка CA</h3>

              <h4>Google Chrome / Chromium</h4>
              <ol className="help-numbered">
                <li>Откройте <code>chrome://settings/certificates</code></li>
                <li>Перейдите на вкладку <strong>Authorities</strong></li>
                <li>Нажмите <strong>Import</strong></li>
                <li>Выберите файл <code>certs/ca.crt</code> с сервера</li>
                <li>Поставьте галочку <em>Trust this certificate for identifying websites</em></li>
                <li>Перезапустите Chrome</li>
              </ol>

              <h4>Mozilla Firefox</h4>
              <ol className="help-numbered">
                <li>Откройте <code>about:preferences#privacy</code></li>
                <li>Прокрутите вниз → <strong>View Certificates</strong></li>
                <li>Вкладка <strong>Authorities</strong> → <strong>Import</strong></li>
                <li>Выберите <code>certs/ca.crt</code></li>
                <li>Поставьте галочку <em>Trust this CA to identify websites</em></li>
              </ol>

              <h4>Linux (системный)</h4>
              <pre><code>{`sudo cp certs/ca.crt /usr/local/share/ca-certificates/anyrest-ca.crt
sudo update-ca-certificates`}</code></pre>

              <h4>Windows</h4>
              <pre><code>{`certutil -addstore -f "ROOT" certs\\ca.crt`}</code></pre>

              <h4>macOS</h4>
              <pre><code>{`sudo security add-trusted-cert -d -r trustRoot \\
  -k /Library/Keychains/System.keychain certs/ca.crt`}</code></pre>

              <p>
                Скачать CA-сертификат:&nbsp;
                <a href="/certs/ca.crt" download="anyrest-ca.crt" className="help-link">
                  anyrest-ca.crt
                </a>
              </p>
            </section>

            {/* ── Security ── */}
            <section id="security">
              <h2>Безопасность</h2>

              <table className="help-table">
                <thead>
                  <tr><th>Уровень</th><th>Механизм</th></tr>
                </thead>
                <tbody>
                  <tr>
                    <td>Транспорт</td>
                    <td>TLS 1.3 (HTTPS/WSS) — данные между браузером и сервером</td>
                  </tr>
                  <tr>
                    <td>Медиа P2P</td>
                    <td>DTLS 1.3 + SRTP / AES-256-GCM — сквозное шифрование</td>
                  </tr>
                  <tr>
                    <td>Relay</td>
                    <td>HMAC-SHA256 с временны́м окном — токен живёт 30 секунд</td>
                  </tr>
                  <tr>
                    <td>Сертификат</td>
                    <td>Self-signed CA с IP-SAN — устанавливается в системное хранилище</td>
                  </tr>
                  <tr>
                    <td>Облако</td>
                    <td>Отсутствует — весь трафик остаётся внутри вашей сети</td>
                  </tr>
                </tbody>
              </table>

              <div className="help-note warn">
                <strong>Рекомендации:</strong> смените <code>RELAY_SECRET</code> в файле
                <code>.env</code> перед деплоем. Не используйте значение по умолчанию
                <code>change-me-please</code> в продакшне.
              </div>
            </section>

            {/* ── Troubleshooting ── */}
            <section id="troubleshooting">
              <h2>Устранение проблем</h2>

              <div className="faq-item">
                <div className="faq-q">Браузер показывает «Небезопасное соединение»</div>
                <div className="faq-a">
                  Установите CA-сертификат в браузер (см. раздел «Сертификаты» выше).
                  После установки перезапустите браузер.
                </div>
              </div>

              <div className="faq-item">
                <div className="faq-q">Статус «Connecting…» и соединение не устанавливается</div>
                <div className="faq-a">
                  <ol>
                    <li>Проверьте, что агент запущен: <code>docker logs anyrest-agent</code></li>
                    <li>Убедитесь, что ID введён правильно (9 цифр)</li>
                    <li>Проверьте порт relay: <code>8081/tcp</code> должен быть открыт</li>
                    <li>Проверьте подключение к серверу: статус «Server online» в шапке</li>
                  </ol>
                </div>
              </div>

              <div className="faq-item">
                <div className="faq-q">Экран агента не отображается (чёрный canvas)</div>
                <div className="faq-a">
                  На Linux агент требует запущенного X-сервера. Проверьте переменную
                  <code>DISPLAY</code>: <code>echo $DISPLAY</code> должна вернуть
                  <code>:0</code> или аналог. Если агент в Docker, убедитесь что
                  <code>/tmp/.X11-unix</code> смонтирован.
                </div>
              </div>

              <div className="faq-item">
                <div className="faq-q">Клавиатура не работает на удалённом ПК</div>
                <div className="faq-a">
                  Убедитесь, что <code>xdotool</code> установлен на агент-машине:
                  <code>apt install xdotool</code>. Кликните один раз по области экрана
                  чтобы передать фокус.
                </div>
              </div>

              <div className="faq-item">
                <div className="faq-q">Высокая задержка / низкий FPS</div>
                <div className="faq-a">
                  Снизьте качество JPEG: запустите агент с флагом <code>-quality 50</code>
                  или уменьшите FPS: <code>-fps 10</code>. На медленных каналах
                  рекомендуется качество 50–60, FPS 10.
                </div>
              </div>

              <div className="faq-item">
                <div className="faq-q">Как проверить статус всех сервисов?</div>
                <div className="faq-a">
                  <pre><code>{`docker compose ps
docker compose logs -f`}</code></pre>
                  Endpoint состояния сервера:
                  <pre><code>{`curl -k https://${serverHost}/health`}</code></pre>
                </div>
              </div>
            </section>

          </div>{/* /help-content */}
        </div>{/* /help-body */}
      </div>{/* /help-panel */}
    </div>
  );
};
