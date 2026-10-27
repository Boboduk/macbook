# Исследование и технический план

## 1. Что удалось выяснить об Alcove

Официальный сайт `tryalcove.com` из среды разработки недоступен: прокси отклоняет соединение
(`CONNECT 403`). Поэтому сведения ниже собраны из публичных обзоров и каталогов, найденных
веб-поиском, а не с самого сайта. Исходный код Alcove закрыт и не изучался.

| Что известно | Источник |
|---|---|
| Превращает вырез камеры MacBook в «Dynamic Island»: плавные переходы, уведомления, Live Activities | AlternativeTo, SlashGear |
| Жесты свайпа, настраиваемые HUD громкости и яркости, которые заменяют системные | AlternativeTo, Theodore HQ |
| Управление музыкой в вырезе; начиная с macOS 15.4 полные данные (обложка, трек) приходят только от Spotify и Apple Music | отзыв на AlternativeTo |
| Календарь и напоминания о событиях, отображение подключения AirPods и изменения громкости | SlashGear, appgefahren.de |
| Виджеты на экране блокировки | Theodore HQ |
| Полки файлов (file shelf) нет | notchy.dev, notchbay.com |
| Платное приложение (~$14–17), пробный период 48 часов, macOS 14+/15+ (данные расходятся) | Homebrew, SlashGear, supernotch.ai |

Источники: [AlternativeTo](https://alternativeto.net/software/alcove/about),
[SlashGear](https://www.slashgear.com/2175261/macos-apps-give-features-apple-doesnt-include/),
[Theodore HQ](https://www.theodorehq.com/macdept/app/alcove),
[appgefahren.de](https://www.appgefahren.de/alcove-bringt-die-dynamic-island-auf-den-mac-394469.html),
[notchy.dev](https://notchy.dev/blog/notchnook-vs-boring-notch-vs-alcove/),
[notchbay.com](https://notchbay.com/blog/notchnook-vs-alcove/),
[supernotch.ai](https://www.supernotch.ai/vs/alcove),
[Homebrew](https://formulae.brew.sh/cask/alcove).

Чего источники **не** раскрывают (и что здесь спроектировано самостоятельно): точные кривые
анимаций, размеры острова, набор настроек, поведение в полноэкранном режиме. Эти решения
приняты по общей логике Dynamic Island и рекомендациям Apple HIG.

## 2. Концепция нашей реализации

Остров — это чёрная фигура, которая в покое совпадает с вырезом камеры. Из неё «вырастают»
состояния:

| Состояние | Что видит пользователь |
|---|---|
| **Idle** (A) | Фигура точно по размеру выреза, визуально незаметна |
| **Hover** (B) | Лёгкое увеличение; при включённой настройке — раскрытие после задержки |
| **Compact** (live) | «Крылья» по сторонам выреза: обложка + индикатор воспроизведения, таймер, HUD громкости/яркости, заряд |
| **Banner** (D) | Остров опускается ниже выреза: уведомление, смена трека, окончание таймера |
| **Expanded** (C) | Полная панель с вкладками «Музыка» / «Таймер», кнопки закрепления и настроек |
| **Pinned** (E) | Expanded, который не закрывается при уходе курсора |
| **Fallback** (F) | Нет данных/разрешений → понятное пустое состояние с кнопкой действия, а не пустой UI |

## 3. Архитектура

```
Packages/IslandCore      ← чистый Swift + Foundation, тестируется на macOS и Linux
  Activity, ActivityManager   — единая очередь активностей (приоритеты, вытеснение, удержание)
  IslandController            — конечный автомат: hover / tap / swipe / pin → IslandPresentation
  EventRouter                 — события модулей + настройки → Activity
  IslandLayout                — размеры и радиусы для каждого состояния (без жёстких координат)
  IslandSettings              — Codable-настройки с миграцией и проверкой диапазонов
  CountdownTimer / Stopwatch  — таймеры на основе дат (без тиков)
  NowPlayingParser, MediaKeyEvent, ScrollGestureRecognizer, TimeFormatting

AlcoveInspired (macOS-приложение, AppKit + SwiftUI)
  App/        точка входа, AppDelegate, AppModel (DI-контейнер), status item, окно настроек
  Core/       IslandCoordinator — мост между Core и UI/окном; MainQueueScheduler
  Window/     IslandPanel (NSPanel), геометрия выреза, DisplayObserver, MouseTracker, FullscreenDetector
  Services/   CoreAudio, DisplayServices, разрешения, вход в систему, питание, настройки
  Features/   Music (Apple Events), Volume, Brightness, Timer, Power, Notifications, MediaKeys
  UI/         SwiftUI-представления острова, анимации, окно настроек
```

Ключевые решения:

* **Одно окно на всё время работы.** `NSPanel` максимального размера создаётся один раз; меняется
  только SwiftUI-содержимое. Окно не меняет размер во время анимаций, поэтому нет мерцания.
* **Клики проходят сквозь окно.** `ignoresMouseEvents` переключается по положению курсора
  относительно *текущей* фигуры острова (глобальный монитор `mouseMoved` не требует разрешений).
* **Ноль опроса в покое.** Все источники событийные: CoreAudio property listeners,
  распределённые уведомления Music/Spotify, IOKit power source notifications, NSWorkspace,
  `didChangeScreenParametersNotification`. Таймеры UI (`TimelineView`) работают только пока
  виден соответствующий элемент.
* **Индикатор воспроизведения на Core Animation**: бесконечные `CABasicAnimation` выполняются
  в render server и почти не нагружают CPU приложения.

## 4. Ограничения macOS и выбранные альтернативы

| Задача | Ограничение | Решение |
|---|---|---|
| «Сейчас играет» для любого плеера | `MediaRemote` — приватный фреймворк, с macOS 15.4 закрыт для сторонних приложений | Apple Music и Spotify через публичные распределённые уведомления + Apple Events (с разрешением Automation) |
| Громкость | Публичный CoreAudio | Чтение, изменение и подписка через `AudioObject*` API |
| Яркость встроенного дисплея (Apple Silicon) | Публичного API нет | `DisplayServices` загружается через `dlopen` (только чтение/запись уровня); при отсутствии символов модуль показывает «недоступно» |
| Событие «изменилась яркость» | Публичного уведомления нет | Отслеживание клавиш яркости через `CGEventTap` (разрешение «Универсальный доступ»), затем чтение уровня |
| Скрыть системный HUD | Публичного API нет | Опция «Заменить системный HUD»: перехват медиаклавиш через `CGEventTap` и изменение громкости/яркости самим приложением |
| Уведомления других приложений | Содержимое Центра уведомлений недоступно | Показываются только события самого приложения и встроенных модулей |
| Экран блокировки | Требует приватных SkyLight API | Не реализовано |

## 5. Этапы

1. Основа: проект, жизненный цикл, панель, позиционирование у выреза, compact/expanded.
2. Анимации: пружинное раскрытие, переходы содержимого, отсутствие скачков.
3. Функции: таймер/секундомер, музыка, система временных событий.
4. Системные: громкость, яркость, питание, уведомления, разрешения.
5. Настройки: окно, сохранение, вход в систему.
6. Тесты, CI-сборка на macOS, Release, инструкция.
