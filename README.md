# Split DNS

Разные DNS-серверы для разных доменов: например, YouTube и Google через Quad9, нейросети через GeoHide, всё остальное через обычный DNS.

- **Windows** — правила [NRPT](https://learn.microsoft.com/windows-server/networking/dns/deploy/nrpt): [Открыть сайт](https://fordownloads.github.io/SplitDNS)
- **Android (KernelSU/Magisk)** — модуль с локальным [dnsproxy](https://github.com/AdguardTeam/dnsproxy) и WebUI

## Зачем это нужно?

- "Умные" DNS сервисы нестабильные и часто отваливаются, поэтому лучше применять их к тем сайтам, которые они "обходят", чтобы не ложить всю сеть
- DNS могут подменять домены, которые вы хотите открывать напрямую
- Один DNS подменяет больше доменов, чем другой, но при этом менее стабилен
- DoH/DoT для всего на Android
- Работает на всех сетях универсально

## Как использовать?

Для Windows:

1. [Откройте сайт](https://fordownloads.github.io/SplitDNS)
2. Добавьте DNS, например GeoHide
3. Задайте ему домены, например "Список GeoHide"
4. По желанию задайте Глобальный DNS, куда будут идти все остальные запросы, например Quad9 (провайдеры на данный момент подделывают запросы к Google и Cloudflare)
5. Скачайте .bat и запустите
6. Примените или отключите правила в .bat файле

## Android

1. Установите splitdns.zip в KernelSU или Magisk с поддержкой KSUWebUI. Перезагрузитесь.
2. Добавьте DNS (например, GeoHide)
3. Задайте ему домены (например, "Список GeoHide")
4. По желанию задайте Глобальный DNS, куда будут идти все остальные запросы (например, Quad9, т.к. провайдеры на данный момент подделывают запросы к Google и Cloudflare)
5. Режим "Заменять системный DNS":
   - **вкл** — весь DNS телефона перенаправляется на dnsproxy через iptables
   - **выкл** — перехватываются только запросы к `192.0.2.53`: укажите этот адрес как DNS в трехбуквенном клиенте
6. Включите "Изменить DNS", перезагрузка не требуется

Конфигурация находится в `/data/adb/splitdns/domains.txt`, лог — `/data/adb/splitdns/splitdns.log`.
Отключите Private DNS: он идёт мимо модуля.

Команды: `sh /data/adb/modules/splitdns/splitdns.sh start|stop|restart|enable|disable|redirect-on|redirect-off|status`.
