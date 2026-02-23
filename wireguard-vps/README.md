# WireGuard VPS + PPTP Bridge для роутера

Роутер не поддерживает WireGuard? Не проблема. VPS выступает мостом: роутер подключается по PPTP (который поддерживают почти все роутеры), а VPS обеспечивает WireGuard для остальных устройств и (опционально) гонит весь трафик через внешний WG-провайдер.

## Архитектура

### Вариант A: VPS как WireGuard-сервер + PPTP для роутера

```
                    ┌─────────────────────────────┐
                    │           VPS                │
                    │                              │
[Роутер] ──PPTP──▶ │  pptpd ──▶ NAT ──▶ eth0 ──▶ │──▶ Интернет
                    │                              │
[Телефон] ──WG───▶ │  wg0   ──▶ NAT ──▶ eth0 ──▶ │──▶ Интернет
[Ноутбук] ──WG──▶ │                              │
                    └─────────────────────────────┘
```

- Роутер подключается по PPTP (как сейчас)
- Телефоны/ноутбуки подключаются напрямую по WireGuard
- Весь трафик выходит через VPS

### Вариант B: PPTP → VPS → Внешний WireGuard VPN

```
                    ┌─────────────────────────────────────┐
                    │              VPS                      │
                    │                                      │
[Роутер] ──PPTP──▶ │  pptpd ──▶ policy routing ──▶ wg-up │──WG──▶ [VPN провайдер] ──▶ Интернет
                    │                                      │
[Телефон] ──WG───▶ │  wg0   ──▶ NAT ──▶ eth0 ──────────▶ │──▶ Интернет (напрямую)
                    └─────────────────────────────────────┘
```

- Трафик роутера идет через внешний WG VPN (Mullvad, IVPN, и т.д.)
- Прямые WG клиенты идут напрямую через VPS
- Policy-based routing разделяет потоки

## Быстрый старт (bare metal)

### 1. Базовая установка (Вариант A)

```bash
# На VPS (Ubuntu/Debian), от root:
wget -O setup.sh https://raw.githubusercontent.com/.../setup-baremetal.sh
chmod +x setup.sh

# Опционально задать переменные:
export PPTP_USERNAME="router"
export PPTP_PASSWORD="my-strong-password"
export WG_PEER_COUNT=3   # кол-во WG клиентов

./setup-baremetal.sh
```

Скрипт:
- Установит WireGuard и pptpd
- Сгенерирует ключи и конфиги для WG-пиров
- Настроит PPTP с MPPE-128 шифрованием
- Настроит iptables (NAT, forwarding)
- Включит автозапуск

### 2. Настройка роутера

В настройках VPN роутера:
- **Тип:** PPTP
- **Сервер:** IP вашего VPS
- **Логин:** `router` (или что задали в PPTP_USERNAME)
- **Пароль:** из вывода скрипта или `/root/vpn-credentials.txt`
- **Шифрование:** MPPE 128-bit (обязательно)

### 3. Подключение устройств по WireGuard

```bash
# Показать QR-код для телефона:
cat /etc/wireguard/peers/peer1/peer1_qr.txt

# Конфиг для импорта:
cat /etc/wireguard/peers/peer1/peer1.conf
```

### 4. (Опционально) Внешний WG VPN для трафика роутера (Вариант B)

```bash
# Скачайте .conf от вашего WG провайдера, затем:
./setup-upstream-wg.sh /path/to/mullvad-wg.conf
```

Трафик роутера пойдет через внешний VPN, остальные клиенты — напрямую.

## Добавление нового WG-пира

```bash
./add-wg-peer.sh имя_пира
```

Добавляет пир без перезапуска (hot-reload), генерирует конфиг и QR-код.

## Docker вариант

Если предпочитаете Docker:

```bash
cp .env.example .env
# Отредактируйте .env
docker compose up -d
```

## Управление

```bash
# Статус WireGuard
wg show

# Статус PPTP
systemctl status pptpd

# Подключенные PPTP клиенты
ip addr show | grep ppp

# Логи
journalctl -u wg-quick@wg0 -f
journalctl -u pptpd -f

# Перезапуск
systemctl restart wg-quick@wg0
systemctl restart pptpd
```

## Безопасность

- PPTP с MPPE-128 — не идеален, но приемлем для роутера без альтернатив
- WireGuard клиенты используют полноценное современное шифрование
- Все ключи генерируются локально, PSK добавлен для пост-квантовой защиты
- Credentials хранятся в `/root/vpn-credentials.txt` (chmod 600)

## Альтернативы PPTP для роутеров

Если ваш роутер поддерживает что-то кроме PPTP, предпочтительнее:

| Протокол | Безопасность | Поддержка роутерами |
|----------|-------------|---------------------|
| **L2TP/IPsec** | Хорошая | Широкая |
| **IKEv2/IPsec** | Отличная | Средняя |
| **OpenVPN** | Отличная | OpenWrt, Asus, Keenetic |
| **SSTP** | Хорошая | Keenetic |
| **PPTP** | Слабая | Почти все |
| **WireGuard** | Отличная | OpenWrt, Keenetic (новые) |

## Структура файлов

```
wireguard-vps/
├── setup-baremetal.sh       # Основной скрипт установки
├── setup-upstream-wg.sh     # Мост PPTP→внешний WG VPN
├── add-wg-peer.sh           # Добавление WG-пира
├── docker-compose.yml       # Docker вариант
├── .env.example             # Пример переменных
├── pptpd.dockerfile         # Docker: PPTP сервер
├── router.dockerfile        # Docker: маршрутизатор
├── scripts/
│   ├── pptpd-entrypoint.sh  # Entrypoint для PPTP контейнера
│   └── router-entrypoint.sh # Entrypoint для роутера
└── configs/                 # Генерируемые конфиги (gitignored)
```
