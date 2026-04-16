# ruRoute v2.0.0

**Умный split-routing для VPN серверов**

Российские сервисы идут напрямую через российский IP, весь остальной трафик — через зарубежный сервер. Клиентам ничего менять не нужно — всё происходит на стороне сервера автоматически.

---

## ⚠️ Важно — куда устанавливать

**Скрипт устанавливается ТОЛЬКО на российский сервер** — тот к которому подключаются клиенты.

```
Клиент (любой протокол: VLESS, VMess, Trojan...)
        ↓
✅ RU сервер ← сюда ставим ruRoute
        ↓
❌ NL/EU сервер ← сюда НЕ нужно
        ↓
     Интернет
```

На зарубежном сервере ничего делать не нужно. Ключи клиентам менять не нужно.

---

## Как это работает

```
Клиент
  ↓
RU сервер
  ↓
  ├── gosuslugi.ru  → прямо (RU IP) ✅
  ├── sberbank.ru   → прямо (RU IP) ✅
  ├── youtube.com   → NL сервер    🌍
  └── instagram.com → NL сервер    🌍
```

---

## Поддерживаемые панели

| Панель | Статус |
|--------|--------|
| 3x-ui | ✅ |
| Marzban | ✅ |
| Hiddify (xray) | ✅ |
| Hiddify (sing-box) | ✅ |
| Чистый xray | ✅ |

---

## Требования

- Ubuntu 20.04+ / Debian 10+ / CentOS 8+
- Минимум 1GB RAM (рекомендуется 2GB)
- Root доступ

---

## Установка

```bash
curl -fsSL https://raw.githubusercontent.com/hjty-0/ruRoute/main/install.sh -o /tmp/install.sh && bash /tmp/install.sh
```

Скрипт автоматически:
- Определит панель (3x-ui, Marzban, Hiddify)
- Скачает базы доменов (~1.3М доменов из 4 источников)
- Установит Go и соберёт `geosite.dat`
- Настроит DNS через Яндекс для российских сервисов
- Пропатчит БД панели — настройки сохранятся навсегда
- Настроит автообновление каждую ночь в 3:00

---

## Источники баз доменов

| Источник | Доменов |
|----------|---------|
| ruRoute ручная база | ~1100 |
| [itdoginfo/allow-domains](https://github.com/itdoginfo/allow-domains) | ~1200 |
| [hxehex/russia-mobile-internet-whitelist](https://github.com/hxehex/russia-mobile-internet-whitelist) | ~900 |
| [antifilter.download](https://antifilter.download) | ~1.35М |

Все источники объединяются в `geosite.dat`. В конфиге xray одна строка: `geosite:ruroute`.

---

## Про предупреждение "выключите VPN"

Некоторые банки проверяют ASN провайдера сервера. Если сервер в датацентре (Яндекс Облако, Hetzner и т.д.) — приложение может показывать предупреждение даже при российском IP.

Это не баг ruRoute — это политика банка. Само приложение при этом работает.

Решение: VPS у провайдера с менее известным ASN (Selectel, Timeweb, региональные провайдеры).

---

## Полезные команды

```bash
# Логи
tail -f /var/log/ruroute.log

# Обновить базы
bash /usr/local/ruRoute/update-lists.sh

# Пересобрать geosite.dat
bash /usr/local/ruRoute/build-geosite.sh

# Удалить
bash /usr/local/ruRoute/uninstall.sh
```

---

## Добавить домен в базу

Открой [Discussions](https://github.com/hjty-0/ruRoute/discussions) и напиши какой домен нужно добавить.

---

## Лицензия

MIT
