# NetWatch — діагностика Ethernet у Windows 11

NetWatch лише спостерігає: він не перезапускає адаптер/служби, не поновлює DHCP,
не змінює драйвер, реєстр, маршрути чи енергозбереження. Журнали Windows читаються
у поточному стані; вимкнені журнали скрипт сам не вмикає.

## Швидкий запуск

Відкрий **64-бітний Windows PowerShell від адміністратора**:

```powershell
Set-Location 'D:\Projects\01 Github\homelab-infra-config\scripts'
.\NetWatch.ps1 -LanTarget 192.168.50.4
```

За потреби дозволити виконання лише для цього процесу:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\NetWatch.ps1" -LanTarget 192.168.50.4
```

Зупинка: **Ctrl+C**. Якщо запускаєш без адміністратора, частина джерел може бути
недоступна; це відображається в diagnostics та collection-errors.txt.
Скрипт розрахований на Windows PowerShell 5.1; синтаксис також сумісний з
PowerShell 7, але останній окремо не перевірявся на цьому ПК.

LAN target необов'язковий. За кількох фізичних Ethernet-адаптерів вибирається
активний з найменшою сумарною метрикою default route серед Ethernet-кандидатів.
Для явного вибору:

```powershell
.\NetWatch.ps1 -AdapterName 'Ethernet' -LanTarget 192.168.50.4
```

Вибір закріплюється за **InterfaceGuid** до завершення процесу; зміна ifIndex
чи тимчасове зникнення пристрою не переключить моніторинг на Wi-Fi.

## Постійний фоновий запуск

З тієї ж папки, **від адміністратора**:

```powershell
.\Install-NetWatch.ps1 -LanTarget 192.168.50.4 -StartNow
```

Інсталятор копіює чотири робочі файли у **C:\Program Files\NetWatch**,
захищає код/конфігурацію від запису звичайними користувачами та створює
завдання **NetWatch-Ethernet**:

- SYSTEM, найвищі права, прихований запуск без відкритого вікна;
- тригери startup та logon, дублікати запусків ігноруються;
- необмежений час роботи, робота від батареї;
- повторний запуск через хвилину після помилки, до 999 спроб.

Без -StartNow завдання почне працювати при наступному startup/logon.
Повторне встановлення оновлює власне завдання та файли, але не видаляє логи.
Інсталятор та деінсталятор підтримують -WhatIf.
Сам факт створення цих скриптів **не встановлює** завдання.

Параметри встановленого монітора:
**C:\Program Files\NetWatch\NetWatch.config.json**.
Зміни конфігурації набувають чинності після наступного запуску монітора.
Під час оновлення завдання може перерватися останній збір знімка.

## Перевірка роботи

```powershell
Get-ScheduledTask -TaskName NetWatch-Ethernet | Select-Object TaskName, State
Get-ScheduledTaskInfo -TaskName NetWatch-Ethernet
$h = Get-Content C:\Logs\NetWatch\heartbeat.json -Raw | ConvertFrom-Json
$h
'Heartbeat age, seconds: {0:N1}' -f ((Get-Date) - [datetime]$h.Timestamp).TotalSeconds
Get-Content ("C:\Logs\NetWatch\netwatch-{0}.csv" -f (Get-Date -Format yyyy-MM-dd)) -Tail 5
```

Heartbeat оновлюється кожні ~5 секунд. Перевіряй одночасно Running та свіжість
heartbeat (зазвичай менше 15 секунд). Сам файл може залишитися від старого запуску.
Код LastTaskResult 267009 / 0x41301 означає, що завдання ще працює.

Один LogRoot допускає лише один процес — це забезпечує ексклюзивний файловий lock.
Наявність netwatch.lock після зупинки нормальна; важливий відкритий дескриптор,
а не існування файла.

## Що записується

Типова структура:

```text
C:\Logs\NetWatch\
  heartbeat.json
  session-<час>-<PID>.json
  netwatch-YYYY-MM-DD.csv
  diagnostics-YYYY-MM-DD.jsonl
  event-cursors.json
  metrics\extended-YYYY-MM-DD.jsonl
  events\events-YYYY-MM-DD.jsonl
  snapshots\startup-<session>\
  incidents\<час>-<PID>\
    summary.txt
    timeline.txt
    samples-YYYY-MM-DD.csv
    events.jsonl
    start-snapshot\
    recovery-snapshot\
```

- **Кожну секунду:** Status, MediaConnectionState, швидкість у біт/с,
  IPv4, ifIndex/GUID, Ethernet gateway, усі IPv4 default routes та їхні метрики,
  ICMP до gateway, LAN target і двох Internet IP. Є тривалість збору sample.
- **Кожні 5 секунд:** DNS A-запит до першого IPv4 DNS-сервера Ethernet,
  статистика адаптера та її дельти, DHCP/lease/subnet, кількість UDP endpoints
  і десять процесів із найбільшою кількістю endpoint.
- **Windows Events:** System (мережеві providers, драйвер, PnP, power),
  доступні NDIS/NetworkProfile/DHCP/DNS/Kernel-PnP журнали.
  Provider драйвера визначається з DriverFileName, резервно — ServiceName.
  Зберігаються час, provider, ID, level, message, XML і RecordId.
- **На старті та при інциденті:** adapter/IP/routes/DNS, ipconfig, arp,
  netstat, CIM, PnP, advanced properties, bindings, процеси й endpoints.

ICMP використовує Windows **IcmpSendEcho2Ex з SourceAddress Ethernet**.
DNS — окремий UDP-сокет, прив'язаний до IPv4 Ethernet, без системного DNS-кешу.
Проби запускаються паралельно, мають тайм-аут і закривають handles/sockets.
Wi-Fi не використовується як автоматична заміна джерела проб.
При відсутності джерела проба позначається NOT_TESTED.

DNS — це перевірка UDP A-відповіді конкретного сервера, не повна перевірка
системного резолвера, DoH, NRPT чи TCP fallback. TRUNCATED/RCODE/NO_ANSWER
зберігаються явно. IPv6, VPN split routing і реальна пропускна здатність
2,5 Гбіт/с цим монітором не тестуються.

Розширені показники та DNS мають власні timestamps; між оновленнями значення
можуть бути попередніми. Помилка джерела не означає нуль помилок у мережі:
дивись diagnostics, source error, timestamp та NOT_TESTED/ERROR.
Зниження накопичувального лічильника позначається CounterReset, дельта тоді null.

## Інциденти

При підтвердженій аномалії створюється окрема папка з:

1. буфером попередніх 60 секунд;
2. усіма samples під час збою;
3. 60 секундами після відновлення;
4. знімком стану, timeline та пов'язаними за часом Windows Events.

Повторний збій у межах post-context продовжує поточний інцидент.
Короткі зміни IP/route/lease/speed позначаються marker; вони теж можуть створити
інцидент, але самі по собі не доводять несправність. Поточний інцидент пишеться
на диск поступово, а не тримається необмежено в RAM.
Після примусового завершення процесу частина контексту може бути неповною.

Класифікації описують **спостереження**, а не остаточну причину:

| Клас | Спостереження |
|---|---|
| PHYSICAL_LINK_DROP | Драйвер повідомив не-Up / disconnected або адаптер зник |
| GATEWAY_LOSS_WHILE_LINK_UP | Лінк Up, gateway не відповів кілька разів |
| INTERNET_UPSTREAM_LOSS | Gateway відповідає, обидва Internet ICMP targets не відповідають |
| DNS_FAILURE | Internet ICMP працює, кілька DNS-проб поспіль невдалі |
| IP_CONFIGURATION_CHANGE | Немає придатного IP/gateway або змінилися IP/routes/lease |
| LINK_SPEED_DEGRADED / LINK_SPEED_CHANGE | Швидкість нижча очікуваної / змінилася |
| ADAPTER_RESET | Є відповідна подія драйвера/NDIS |
| PORT_EXHAUSTION | Є Tcpip 4231 або 4266 |
| MONITOR_SOURCE_ERROR / PROBE_ERROR | Помилка самого джерела діагностики |

Навіть PHYSICAL_LINK_DROP не доводить несправність кабелю: драйвер або свіч
також можуть спричинити такий стан. Втрата ICMP одного зовнішнього target не
вважається втратою інтернету. ICMP gateway теж може обмежуватися роутером.

Почни аналіз наступного обриву з **incidents\...\summary.txt**, далі timeline,
samples, events та snapshots. Якщо потрібно передати дані для аналізу,
достатньо папки інциденту, session metadata і extended metrics за відповідний час.
Знімки містять локальні IP, MAC, назви процесів/пристроїв; перевір їх перед
публічним поширенням.

## Частота, ресурси та обмеження

Основний інтервал — 1 секунда, extended/DNS — 5 секунд.
Важкий collector і snapshots працюють в окремих runspaces: максимум один кожного
типу. Collector обмежений ~30 секундами, snapshot — ~45; недоступні джерела
записуються окремо. Одночасний додатковий snapshot може бути пропущений із
записом у diagnostics. Час знімка може трохи відрізнятися від початку інциденту.

Скрипт не гарантує виявлення лінк-флапу коротшого за інтервал опитування.
NDIS/Operational може не містити link events навіть після ввімкнення —
це вже спостерігалося на цьому ПК. Журнали лише доповнюють polling.
Перевантаження Windows/CIM може збільшити інтервал; це видно за timestamps
та повідомленнями Timing. Це не пакетне захоплення ETW/pcap.

Логи ротуються щодня, **автоматичного видалення немає**.
У CSV приблизно 86 400 рядків на добу за інтервалу 1 с; розмір залежить від
маршрутів та інцидентів. Періодично архівуй старі дні.
Checkpoint по RecordId запобігає повторному читанню подій між штатними запусками;
після аварії між записом події та checkpoint можливий повтор — ключ
Log + RecordId дозволяє його прибрати. Очищення журналу з нижчим RecordId
виявляється, із повторним читанням початкового часового вікна.

Усі параметри доступні через Get-Help .\NetWatch.ps1 -Full.
Очікувана швидкість — 2500000000 біт/с; для іншого адаптера задай
-ExpectedLinkSpeedBps або 0, щоб не перевіряти нижню межу.
Для короткої перевірки доступні -DurationSeconds 20 -SkipSnapshots.

## Зупинка та видалення завдання

М'яка зупинка фонового монітора:

```powershell
New-Item C:\Logs\NetWatch\stop.request -ItemType File -Force
```

Перед наступним ручним запуском видали лише цей marker:

```powershell
Remove-Item C:\Logs\NetWatch\stop.request -ErrorAction SilentlyContinue
Start-ScheduledTask -TaskName NetWatch-Ethernet
```

Видалення автозапуску (від адміністратора):

```powershell
.\Uninstall-NetWatch.ps1
```

Логи та встановлені файли залишаться; мережеві параметри не зміняться.

## Перевірки реалізації

```powershell
.\Test-NetWatch.ps1
.\Test-NetWatch.ps1 -Integration
```

Integration тимчасово підміняє лише результат Get-NetAdapter у тестовому процесі:
реальний NIC не відключається. Перевіряються incident, pre/post-context,
відновлення, CSV escaping та класифікації. Мережеві проби залишаються справжніми.
Артефакти тесту зберігаються у вказаному TestRoot або окремій папці TEMP.

Технічні джерела:
- [Microsoft: IcmpSendEcho2Ex](https://learn.microsoft.com/en-us/windows/win32/api/icmpapi/nf-icmpapi-icmpsendecho2ex)
- [Microsoft: MSFT_NetAdapter](https://learn.microsoft.com/en-us/windows/win32/fwp/wmi/netadaptercimprov/msft-netadapter)

