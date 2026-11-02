# Split DNS

Разные DNS-серверы для разных доменов: например, YouTube и Google через Quad9, нейросети через GeoHide, всё остальное через обычный DNS.

- **Android (KernelSU/Magisk)** — модуль с локальным [dnsproxy](https://github.com/AdguardTeam/dnsproxy) и WebUI.
- **Windows** — правила [NRPT](https://learn.microsoft.com/windows-server/networking/dns/deploy/nrpt): страница **https://fordownloads.github.io/SplitDNS/** собирает `SplitDNS.bat`.

## Конфиг `domains.txt`

Синтаксис как у `hosts`, только вместо IP — DNS-сервер (или несколько через запятую):

```
# @group on Quad9
9.9.9.10,149.112.112.112 google.com .googleapis.com youtube.com
# @group off GeoHide
#@ 159.194.200.33 chatgpt.com claude.ai
# @global
1.1.1.1 *
```

| Запись | Значение |
|---|---|
| `site.com` | домен и его поддомены (на Windows скрипт с сайта добавляет оба правила) |
| `.site.com` | только поддомены |
| `*` | глобальный DNS для всего остального |
| `# @group on\|off <имя>` | начало группы для WebUI; строки выключенной группы пишутся как `#@ …` |

Если домен есть в нескольких группах, побеждает верхняя. Более точный домен (`gemini.google.com`) важнее общего (`google.com`).

DoH/DoT/DoQ (`https://`, `tls://`, `quic://`) работают только на Android. NRPT в Windows принимает только IP.

## Android

1. Соберите модуль: `.\Build-Module.ps1` (скачает dnsproxy и соберёт `splitdns-module.zip`), установите его в KernelSU.
2. Откройте WebUI модуля: группы, порядок перетаскиванием, быстрые списки «Нейросети» и «GeoHide».
3. Режим «Заменять системный DNS»:
   - **вкл** — весь DNS телефона перенаправляется на dnsproxy через iptables;
   - **выкл** — перехватываются только запросы к `192.0.2.53`: укажите этот адрес как DNS в VPN-клиенте. Без VPN DNS не меняется.

Конфиг лежит в `/data/adb/splitdns/domains.txt`, лог — `/data/adb/splitdns/splitdns.log`. Отключите Private DNS: он идёт мимо модуля.

Команды: `sh /data/adb/modules/splitdns/splitdns.sh start|stop|restart|enable|disable|redirect-on|redirect-off|status`.

## Windows

- **Сайт**: настройте группы на https://fordownloads.github.io/SplitDNS/ (хранятся в браузере, есть импорт/экспорт `domains.txt`) и скачайте `SplitDNS.bat`. Скрипт запрашивает права администратора, показывает статус правил и предлагает включить или выключить их.
- **`Apply-SplitDns.ps1`** — применяет `domains.txt` из консоли (от администратора): `-Remove` удаляет правила.
- **`Compare-Dns.ps1`** — резолвит список хостов через несколько DNS и показывает таблицу различий (`summary.txt` — полный CSV).

VPN-клиенты на WireGuard могут стирать правила NRPT при переподключении: тогда просто запустите `.bat` ещё раз.

## Сборка

```powershell
.\Build-Module.ps1              # splitdns-module.zip + SplitDNS-PC.html
.\Build-Module.ps1 -PageOnly    # только страница (так её собирает GitHub Pages)
```

Списки `module/lists/`: `GeoHide-domains.txt` — снимок [Internet-Helper/GeoHideDNS](https://github.com/Internet-Helper/GeoHideDNS), `AI-domains.txt` — его разделы с нейросетями плюс основные AI-сервисы.
