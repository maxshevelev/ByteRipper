# Структуры ME: EOM, Boot Guard, OEM Public Key Hash

Что нашлось в дампах ASUS ROG Flow Z13 (CSME 16.1.25.1991, ADP-LP), сверенное с
конфигом MFIT (`Untitled.xml`, сохранённый проект по этому же дампу) и с отчётом
самого MFIT (`orig.cleanME_NO_EOM_info.txt`). Фьюзы PCH здесь не рассматриваются:
из дампа они не читаются.

## Первоисточники: как MFIT называет эти настройки

Из `Untitled.xml` (проект MFIT, layout `Intel(R) AlderLake P Chipset - Consumer - SPI`):

| поле MFIT | значение в проекте | где лежит по словам MFIT |
|---|---|---|
| `CsePlugin:UEP:BtGuardProfileConfig` | `Boot Guard Profile 5 - FVME` | ME-регион, область UEP |
| `CsePlugin:UEP:OemPublicKeyHash` | `05 C6 97 66 … 84 52` (48 байт) | ME-регион, UEP |
| `CsePlugin:UEP:SecondOemPublicKeyHash` | все нули | ME-регион, UEP |
| `CsePlugin:UEP:BtGuardKeyManifestId` | `0x1` | ME-регион, UEP |
| `CsePlugin:UEP:TxtSupported` | `No` | UEP |
| `CsePlugin:UEP:OemKeyRevEnable` | `No` | UEP |
| `CsePlugin:UEP:PrtcBackupPower` | `None` | UEP |
| `CsePlugin:UEP:FdvEnabled` | `No` | UEP |
| `CsePlugin:UEP:RpmcSupported` / `RpmcRebindEn` | `Yes` / `Yes` | UEP |
| `CsePlugin:UEP:BtGuardCpuDebugEnable` / `BtGuardBspInitEnable` | `Enabled` | UEP |
| `CsePlugin:UEP:PttSupportedFpf` / `DnxEnabled` | `Yes` / `Yes` | UEP |
| `CsePlugin:UEP:OemPlatformId` / `UniquePlatformId` | `0x0` / `0x0` | UEP |
| `CsePlugin:EomNvar:EOM#EomFirstBootEnabled` | `Yes` | NVAR, файл `mca/eom` |
| `CsePlugin:EomNvar:EOM_Config#FlexibleEomSettings` | `Lock Descriptor and OEM Configs` | NVAR, файл `mca/eom_config` |
| `CsePlugin:OEM_KM:OemExtInputFile_path` | `…\Decompose\CsePlugin#OEM_KM.bin` | компонента OEMP |

Дословно из help_text (это и есть ответ на «где ключ и как понять, задан ли он»):

> **OEM Public Key Hash** — «Raw hash string for the **SHA-384 hash of the OEM public key**
> corresponding to the private key used to sign the OEM Key hash manifest. When
> manufacture is completed, this hash value is **burned into an FPF**, and is
> permament. … **OEM signing is disabled when this hash is set to all 0s.**»

> **EOM on First Boot Enabled** — «This setting determines if End of Manufacturing
> will be triggered on first boot of the platform after flashing. Note: **When this
> setting is enabled Intel(R) CSME will enter End of Manufacturing regardless of
> the descriptor settings.**»

> **Flexible EOM setting options** — `['Lock Descriptor and OEM Configs',
> 'Lock OEM Configs Only', 'Lock Descriptor Only', 'Do not lock Descriptor and OEM
> Configs']` — «determines which settings will be automatically commited during
> End of Manufacturing flows».

Отчёт MFIT по cleanME-образу (`orig.cleanME_NO_EOM_info.txt`) печатает те же три
факта человеческими строками — по нему и надо сверять наш вывод:

```
CsePlugin#OEM_KM starting offset: 0x198000
Intel (CS)ME Region version 16.1.25.1991 (Clean, Configured)
Boot Guard Status: BG0 - Boot Guard Disable NO_FVME
EOM (End of Manufacturing) on First Boot Disabled
OEM Public Key Hash (SHA-384): 05c697663a75e912…d2e6fd3e8452
```

## Что это значит для определений

1. **OEM Public Key Hash** = `CsePlugin:UEP:OemPublicKeyHash`, 48-байтный SHA-384,
   в области **UEP** ME-региона. Задан ⇔ не все нули (по help_text: «OEM signing is
   disabled when this hash is set to all 0s»). В Z-дампе встречается **15 раз**:
   9 — внутри MFS-файла `/home/mca/3LVLSCD.dat` (№58, 0x900 = 48 × 48 байт), 6 — в
   UEP (0x2A00A0, 0x2A0150, 0x2A0250, 0x2A10A0, 0x2A1150, 0x2A1250). Второй хеш
   (`SecondOemPublicKeyHash`) — нули; на BIOS-стороне живёт **другой** 32-байтный
   хеш (`Boot Guard Key Manifest`, FIT → 0xF49B00, хеш по 0xF49B24) — это не он.
2. **Уровень Boot Guard** = `CsePlugin:UEP:BtGuardProfileConfig`, значения
   `0 - No_FVME`, `3 - VM`, `4 - FVE`, `5 - FVME`, тоже в UEP. Проект по Z_FLOW
   объявляет `5 - FVME`.
3. **EOM**:
   - `mca/eom` (1 байт) = `EOM#EomFirstBootEnabled` (0/1) — «закроет ли при первой
     загрузке»; в заводском дампе 0x00, в образе `cleanME_EOM` 0x01;
   - `mca/eom_config` (2 байта) = `EOM_Config#FlexibleEomSettings` — перечисление
     из четырёх значений (что именно фиксируется при EOM); в заводском 0x0000.
   Обе записи есть и в OEM-конфигурации (заводское значение), и в живой ФС (что
   стоит сейчас); `/home/mca/eom_flow` — маркер без заводской записи.

## Форматы, проверенные побайтно

- **Дескриптор**: подпись `5A A5 F0 0F` по 0x10, FLMAP0 0x14, FLMAP1 0x18; таблица
  регионов по `(FLMAP0>>16 & 0xFF) << 4` (счёт в старшем байте здесь 0, читать все
  16 слотов), секция мастеров по `(FLMAP1 & 0xFF) << 4`; слово BIOS-мастера
  (v2): `read = w>>8 & 0xFFF`, `write = w>>20 & 0xFFF`. Заводское `0x00F/0x00A`;
  в `cleanME_NO_EOM` — `0xFFF/0xFFF`; в `cleanME_EOM` — `0x00F/0x11A` (это уже
  работа MFIT: он запирает дескриптор той же операцией, что выставляет флаг).
- **OEM-конфигурация (FITC)**: по `payloadOffset` u32-счётчик записей, далее по
  12 байт `{fileID, offset, flags}`; значение = байты по `payloadOffset + offset`.
  File ID: `eom` 0x10020000, `eom_config` 0x1001EE00, `manuf_lock` 0x10020100.
  Суммы: `dataCRC` (FITC+0x0C) = CRC-32 (zlib) по payload; `headerCRC` (+0x04) =
  CRC-32 по первым 12 байтам с обнулённым полем.
- **MFS-файл**: содержимое = первые `size` байт цепочки, далее 16 служебных байт,
  в конце 40-байтная таблица Integrity.
- **UEP** (0x2A0000, 8 КБ в этих образах): контейнер `$UEPC`, u32 размер по +4;
  записи вида `{…, 0x4FE | 0xFE, <адрес окна в BIOS-регионе>, <размер>, <сумма>,
  <Key Manifest ID>, <48-байтный хеш>, …}`; вторая часть области начинается по
  0x2A1000. В заводском дампе полезная часть записана, у образов MFIT —
  стёрта/иная (13 мелких различий в шапке и суммах).

## Опыт «только профиль»: профиль в дампе не отражается

Пара образов, собранных из одного и того же дампа с разным `BtGuardProfileConfig`
(`image_BG3.bin` — `Boot Guard Profile 3 - VM`, `orig.cleanME_NO_EOM.bin` — по
отчёту MFIT `BG0 - No_FVME`), отличается **22 байтами во всём файле**:

| адрес | `image_BG3` | `cleanME_NO_EOM` | что это |
|---|---|---|---|
| 0x80–0x93 | `00 0F A0 11 … 00 01 01 10` | `FF …` | мастер-секция дескриптора: в BG3 она заперта |
| 0x29500C | `A0 B3 5B 66` | `EF 7E 4B 90` | `dataCRC` OEM-конфигурации |
| 0x296F20 | `01 01` | `00 00` | записи `eom` и `eom_config` |

Различие дескриптора объясняется не профилем, а EOM: в проекте BG3
`EomFirstBootEnabled = Yes`, и плагин MFIT запирает дескриптор той же операцией
(у образа `cleanME_EOM` — те же маски `0x00F/0x11A`). Записи `eom`/`eom_config`
тоже изменились из-за EOM, а не профиля. **Ни один байт ME-региона не отличился
от смены профиля** — ни UEP, ни OEM-конфигурация, ни компонента `OEM_KM` по
0x198000.

Отсюда: **номер профиля Boot Guard из дампа не читается.** Он уходит во фьюзы PCH
(платформа прожигает FPF при EOM, и ACM читает политику оттуда), а MFIT печатает
«Boot Guard Status: BG0…» как значение *своего проекта*, не как факт образа.
Подтверждается и help_text самого MFIT: хеш ключа «is burned into an FPF, and is
permament», а подпись в этих сборках выключена (`SigningEnabled = Disabled`), так
что манифесты KM/BPM остаются вендорскими и MFIT их не переписывает.

Что дамп всё-таки показывает про Boot Guard: **OEM Public Key Hash** в UEP (и его
зеркало в `3LVLSCD.dat`), вендорские манифесты KM/BPM в BIOS-регионе, состояние
дескриптора. Про профиль — только «Boot Guard настроен» (UEP заполнен, ключ не
нулевой), но не его номер.

### Прежняя гипотеза (опровергнута)

Ранее по слову `container+0x68` предполагалось одноразрядное кодирование профиля:
`0x00` = профиль 0, `0x04` = профиль 5. Опыт BG3 её снял: у профиля 3 третий байт
тоже `0x00`, а слово целиком (`0x000000FE`) совпадает с образом профиля 0. Бит
`0x400` отличает **заполненный** UEP (образ с платы, где manufacturing прошёл) от
пустого UEP сборки MFIT или образа обновления, а не уровень.

## Слово настроек UEP: чем «настроен» отличается от «не настроен»

Первые 0x100 байт контейнера UEP — фиксированные поля, и одно из них
(`u32` по `container+0x68`) отличает образы с **заполненным** UEP (снятые с платы,
прошедшей manufacturing) от образов, где UEP пуст (сборки MFIT, образы обновления).
Сводка по 36 дампам коллекции (`~/Desktop/ME` и дампы ASUS/Lenovo):

| `+0x68` | дампы |
|---|---|
| `0x000004FE` | ASUS Z Flow (orig_30072026.BIN — копия того же), Dell SPI_EF4020 |
| `0x0000047E` | ASUS SPI_C27519, Dell SPI_EF4019, Lenovo LENV_all, Lenovo SPI_ALL_192Mbit, **Lenovo Legion SPI_ALL** |
| `0x00000472` | CSME 15.bin, Dell SPI_204319 |
| `0x00000172` | 1.bin, 1.bin_S0, 2.rom (Lenovo, ключ `3bec…`) |
| `0x000000FE` | CSME 16.1.bin, оба образа MFIT (`cleanME_NO_EOM`/`cleanME_EOM`), `image_BG3` |
| `0x0000007E` | LENV_CSME 16.bin (чистый образ Lenovo), HP EliteBook 630 |
| `0x00000000` | CSME 12.BIN, DELL Optiplex 5070, HP ProDesk, GD25B127D, SPI_EF4018, Original_Bios |

Слово читается как **битовая карта настроек UEP**: младшие два байта — булевы
поля (`0xFE` = семь «Yes»: RpmcSupported, RpmcRebindEn, BtGuardCpuDebugEnable,
BtGuardBspInitEnable, PttSupportedFpf, DnxEnabled и ещё одно), бит `0x400`
второго байта — «UEP заполнен» (он же отличает `0x172`/`0x4xx` серийных плат от
`0x00xx` сборок). Смена профиля это слово не меняет — см. опыт BG3 выше.

Сверка двух проектов по полям дала соответствие одного бита младшего байта:
у ASUS `DnxEnabled = Yes` и бит `0x80` выставлен, у Legion `DnxEnabled = No` — и
бит снят; остальные булевы поля у них совпадают. Это одна пара, то есть бит под
`DnxEnabled` пока лишь правдоподобен.

Соседние поля — не настройки, а окно в BIOS-регионе и его сумма, они разные у
каждого образа: `+0x6C` адрес (0x79ED80, 0x40ED80, 0x03FBED80…), `+0x70` размер
(0x180000, 0x80000), `+0x7C` 32-битная сумма, `+0x80` = Key Manifest ID (0x1).

## Что дамп всё-таки говорит про Boot Guard

Признак, который сработал на всех проверенных парах — **наличие вендорских
манифестов в BIOS-регионе**:

| плата | уровень (со слов пользователя) | `__KEYM__` (Key Manifest) | `__ACBP__` (Boot Policy) | ключ в UEP |
|---|---|---|---|---|
| ASUS Z Flow | 5 | есть (0xF49B00 и копия 0xE59080) | есть (0xF49080 и 0xDF0300) | `05 C6 97 …` |
| Lenovo Legion 5 Pro | 5 | есть | есть | `7C CA BE …` |
| Lenovo 1.bin / 2.rom | 0 | **нет** | **нет** | `3B EC …` (заполнен) |
| cleanME_NO_EOM (сборка MFIT) | 0 (отчёт MFIT) | есть — BIOS вендорский, подпись выключена | есть | `05 C6 97 …` |

То есть у платы, где Boot Guard включён, BIOS несёт Key Manifest и Boot Policy
Manifest (их и показывает панель FIT по записям FIT-таблицы), а у платы с
профилем 0 в этой BIOS их нет вообще. Сборка MFIT сохраняет вендорский BIOS, а с
ним и его манифесты, поэтому по сборке уровень не проверяется — только по дампу с
платы.

**Номер профиля (3/4/5) по дампу не читается** (опыт BG3 выше): он во фьюзах, а
манифесты несут лишь ту политику, которой подписаны. Формально строка панели может
честно сказать «Boot Guard включён: манифесты и ключ есть» / «выключен: ни
манифестов, ни ключа», а для номера нужен либо MEInfo на живой плате, либо разбор
флагов политики в Boot Policy Manifest — для которого нужна плата с уровнем 3 или 4
(у автора таких нет).

## Что ещё не разобрано (честно)

- **Флаги политики внутри Boot Policy Manifest.** Манифест разобран приложением
  только по версии, revision и SVN (`Packages/UEFIImage/.../FITComponents.swift`);
  где в его заголовке лежат биты политики и как они соответствуют профилям 3/4/5 —
  не установлено, и без платы с уровнем 3 или 4 не установится.
- **Семантика полей записи UEP**: адрес/размер окна (в Z-дампе 0x79ED80 и
  0x180000 — окно внутри BIOS-региона), 32-битная сумма 0xCAFC7A36, ключ Manifest
  ID. Формально MFIT пишет `BtGuardKeyManifestId = 0x1`, и `01 00 00 00` в записи
  ему соответствует.
- **Почему хеш встречается 15 раз** (MFS `3LVLSCD.dat` + UEP) — по-видимому,
  «3 level supply chain data» зеркалит UEP; порядок и назначение копий не
  доказаны.
- **Противоречие в правилах MFIT**: сборка отказывается ставить флаг при
  `0xFFFF` в правах BIOS-мастера («not allowed»), а help_text того же поля
  говорит, что при включённом флаге CSME войдёт в EOM «regardless of the
  descriptor settings». Что из этого верно на платформе — проверяется дампом
  после первой загрузки.

## Как читать

`scripts/me_eom.py <dump>…` печатает: состояние дескриптора (заперт ли BIOS-мастер),
адрес `$UEPC` и долю стёртого, записи OEM-конфигурации для трёх EOM-файлов и
повторяющиеся 48-байтные значения ME-региона (хеши ключей). Скрипт — оракул
исследования, не финальное правило: эвристику по 48-байтным повторам заменит
разбор записей UEP, когда профиль будет заякорен.
