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
   disabled when this hash is set to all 0s»). В Z-дампе встречается **12 раз**:
   6 — в ключевой таблице MFS (по 0x21CFCA, 0x21D0D2, 0x21D2E2, 0x21D3EA, 0x21D5FA,
   0x21D702) и 6 — в UEP (по 0x2A00A0, 0x2A0150, 0x2A0250, 0x2A10A0, 0x2A1150,
   0x2A1250). Второй хеш
   (`SecondOemPublicKeyHash`) — нули; на BIOS-стороне живёт **другой** 32-байтный
   хеш (`Boot Guard Key Manifest`, FIT → 0xF49B00, хеш по 0xF49B24) — это не он.
2. **Уровень Boot Guard** = `CsePlugin:UEP:BtGuardProfileConfig`, значения
   `0 - No_FVME`, `3 - VM`, `4 - FVE`, `5 - FVME`. MFIT пишет его **в образ** —
   но не в UEP, а JSON-записью в разделе CDMD (ниже): там он и читается из дампа.
   Проект по Z_FLOW объявляет `5 - FVME`.
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

## Профиль Boot Guard читается из JSON в CDMD

**Профиль в образе есть**, и моё прежнее «не отражается» было ошибкой: пара
`image_BG3.bin` / `orig.cleanME_EOM.bin` оказалась одним и тем же файлом сборки с
профилем 0 (внутри него самого стоит `0`), так что она ничего про профиль не
доказывала.

Источник — раздел **CDMD** (`0x29D000·0x3000` в этих образах, начинается строкой
`FIT AS A FIDDLE`): внутри лежат маленькие JSON-записи настроек, среди них

```
{"BtGuardProfileConfig": 3}
```

Число — **индекс в списке MFIT**: `0` = `0 - No_FVME`, `1` = `3 - VM`,
`2` = `4 - FVE`, `3` = `5 - FVME`. Проверено по всем дампам с известным уровнем:

| дамп | JSON | профиль | истина владельца |
|---|---|---|---|
| `Z_FLOW…orig.bin` | `3` | 5 - FVME | 5 ✓ |
| Legion `SPI_ALL.bin` | `3` | 5 - FVME | 5 ✓ |
| `orig.cleanME_NO_EOM` / `_EOM` / `image_BG3` | `0` | 0 - No_FVME | 0 ✓ |
| `image_BG4.bin` | `2` | **4 - FVE** | 4 ✓ |
| Lenovo `1.bin` / `2.rom` | строки нет | не читается | 0 |

Читается поиском ASCII-строки `"BtGuardProfileConfig"` и числа за ней; рядом в том
же блоке лежат и другие настройки (в `image_BG4` — ещё `{"FpfSvnEnabled": 1}`).
Где блока нет вовсе (`1.bin`, `2.rom` — образы без CDMD-конфигурации), профиль из
дампа не выводится: там остаются только вторичные признаки — вендорские манифесты
KM/BPM в BIOS и заполненный UEP.

Прежняя, ошибочная версия этого раздела опиралась на пару `image_BG3` и
`orig.cleanME_EOM`, отличавшуюся **22 байтами**:

| адрес | BG3 | BG0 | что это |
|---|---|---|---|
| 0x80–0x93 | `00 0F A0 11 …` | `FF …` | мастер-секция дескриптора (заперта из-за EOM) |
| 0x29500C | `A0 B3 5B 66` | `EF 7E 4B 90` | `dataCRC` OEM-конфигурации |
| 0x296F20 | `01 01` | `00 00` | записи `eom` и `eom_config` |

Это различия **EOM**, а не профиля — что верно и по сей день: они и есть след
включения «EOM on first boot» (запертый дескриптор + записи о фиксации).

Что дамп показывает про Boot Guard: **номер профиля** — из JSON в CDMD (выше);
**OEM Public Key Hash** — в UEP (и его зеркало в `3LVLSCD.dat`); вендорские
манифесты KM/BPM в BIOS-регионе и состояние дескриптора — вторичные признаки.
Когда блока CDMD нет, последние остаются единственной опорой.

## Оракул: ожидаемые строки

`scripts/me_eom.py` печатает эти три факта построчно. Проверенные значения (по ним
и сверять правки скрипта); адреса — файловые, то есть от начала дампа:

| дамп | дескриптор BIOS-мастера | `eom` / `eom_config` (FITC 0x295010) | профиль из CDMD |
|---|---|---|---|
| `Z_FLOW…orig.bin` | `0x00F / 0x00A` (locked) | `00` / `00 00` | `3` → **5 - FVME** |
| `orig.cleanME_NO_EOM` | `0xFFF / 0xFFF` (open) | `00` / `00 00` | `0` → 0 - No_FVME |
| `orig.cleanME_EOM` | `0x00F / 0x11A` (locked) | `01` / `01 00` | `0` → 0 - No_FVME |

Хеш Z-дампа — 48 байт `05c6 9766 …` — встречается в образе **12 раз**: оракул
печатает это одной строкой (`12 copies`), из них 6 — в UEP (0x2A00A0, 0x2A0150,
0x2A0250, 0x2A10A0, 0x2A1150, 0x2A1250) и 6 — в ключевой таблице MFS
(0x21CFCA, 0x21D0D2, 0x21D2E2, 0x21D3EA, 0x21D5FA, 0x21D702). Прежняя запись «15
раз» была артефактом: окно, сдвинутое на 4 байта, попадало в соседнюю запись и
считалось отдельным значением; точное сравнение даёт 12. Строки оракула ниже
первого значения (`fe 04 00 00 …`, `367afcca …`, `01 00 00 00 …`) — окна,
захватившие хвост соседней записи, а не другие ключи.

Что оракул **не** печатает: живое значение записей `eom`/`eom_config` — он читает
страницу заводских значений OEM-конфигурации (ту, что есть и в чистом образе). Что
стоит сейчас, лежит в файловой системе MFS, и это читает движок приложения.

Блок CDMD в этих образах лежит по 0x29D000 (сигнатура `FIT AS A FIDDLE`) и несёт
рядом с профилем настройки стенда: `StrapsProject`, `HarnessProject`,
`HarnessLabel`, `HarnessRevision`, `SelectedRvp`, `DbC_Strap_CSME_USB2_DbC_port_enable`,
`ResizeNftpForFtpr`, `sku`, `FpfSvnEnabled` — то есть читать из образа можно не
только профиль. Из этих же строк видно, что `FpfSvnEnabled` у сборок MFIT стоит, а
у заводского Z-дампа его нет.

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

Второй признак, годный только для дампа **с платы** (UEP заполнен движком):
бит `0x400` в слове `container+0x68`. По подтверждённым владельцем дампам:
Z Flow (профиль 5) — `0x4FE`, Legion (5) — `0x47E`, то есть бит есть; Lenovo
1.bin / 2.rom (профиль 0, но UEP заполнен и ключ `3B EC …` на месте) — `0x172`,
бита нет. У сборок MFIT UEP пуст, и бит ничего не значит.

**Номер профиля читается из JSON в CDMD** (раздел выше) — манифесты же несут
лишь ту политику, которой подписаны, и вторым признаком не являются. Если блока
CDMD в образе нет (`1.bin`, `2.rom`), строка панели может честно сказать только
«Boot Guard включён: манифесты и ключ есть» / «выключен: ни манифестов, ни ключа»,
и тогда номер берётся с живой платы через MEInfo — либо остаётся неизвестным.

## База настроек внутри mfit.exe — точная карта FPF/UEP

MFIT возит с собой XML-базу настроек в сжатом виде (zlib-потоки внутри
`mfit.exe`). Она даёт не только имена и значения, но и **физическую карту**: для
каждой настройки — файл (или структура) и смещение с битами. Карта FPF/UEP
(36 полей; смещения внутри структуры, где `OEM_KH_0` — по 0x98):

| поле | смещение | биты |
|---|---|---|
| `OEM_CFG_DONE`, `GLITCH_D_EN` | 0x40 | 0, 1 |
| `OEM_ID` / `KM_ID` / `FW_TYPE` / **`BTG_PROFILE`** | 0x48 | 0–15 / 23–26 / 27–29 / **30–32** |
| `FTPM_EN`, `RPMC_EN`, `FDV_EN`, `TXT_EN`, `OEM_KH_0_V`, `KM_ID_V`, `BTG_PROFILE_V`, `BSP_INIT_DIS`, `CPU_DEBUG_DIS` … | 0x4c | по одному биту |
| `PLAT_ID` / `DNX` / `RPMC_RB` / `CSE_FW_SVN_EN` … | 0x84 | 0–15 / 16 / 17 / 20 |
| **`OEM_KH_0`** / **`OEM_KH_1`** | 0x98 / 0xC8 | 384 бита (48 байт SHA-384) |

Значения профиля: `0 - No_FVME`, `3 - VM`, `4 - FVE`, `5 - FVME` (из
`config_params` настройки), а сам `BtGuardProfileConfig` лежит в секции
`BootGuardConfiguration`.

Для EOM та же база даёт раскладку файла `mca/eom_config` (2 байта): **бит 0 =
`EomFirstBootEnabled`**, **биты 1–2 = `FlexibleEomSettings`** (0 = «Lock Descriptor
and OEM Configs», 1 = «Lock OEM Configs Only», 2 = «Lock Descriptor Only», 3 = «Do
not lock…») — то есть наш образ с `eom_config` = `0x0001` читается как
«EOM при первой загрузке: да, фиксировать дескриптор и OEM-конфигурацию».

Чего карта не решает: в *вендорских* дампах контейнер UEP устроен иначе, чем
ожидает карта (`$UEPC` против `$UEP`, несколько записей с ключом, вторая часть
области по 0x2A1000), поэтому запись с живыми значениями ещё надо опознать —
для этого нужен внешний оракул, и им служит ECFinder.

## Внешний оракул: ECFinder

`ECFinder.exe` (<https://…/Downloads/ECFinder_0>, readme на русском) умеет по дампу
печатать «Boot Guard Status» и сохранять «OEM Public Key Hash (SHA-384)» в
`…_info.txt`; его отчёты владелец дампов и присылал. Что показали прогоны:

| файл | `Boot Guard Status` | состояние ME в его же строке | истинный профиль |
|---|---|---|---|
| `Z_FLOW…orig.bin` | `BG5 - Boot Guard Enabled FV_VME` | Not clean, **Initialized** | 5 |
| `image_BG3.bin` | `BG0 - Boot Guard Disable NO_FVME` | Clean, **Configured** | 0 (файл равен сборке BG0) |
| `orig.cleanME_EOM.bin` | `BG0 - … NO_FVME` | Clean, Configured | 0 |
| Z-дамп с погашенным битом `0x400` в UEP | `BG5` (не изменилось) | Not clean, Initialized | — |
| сборка BG0 с выставленным битом `0x400` | `BG0` (не изменилось) | Clean, Configured | — |

Отсюда: **бит `0x400` к вердикту отношения не имеет** (копии не изменили ответ), а
вердикт идёт в паре с состоянием файловой системы ME: «Initialized» → `BG5`,
«Configured» → `BG0`. Гипотеза, которая сходится со всеми четырьмя файлами:
**«Boot Guard настроен» = в BIOS есть вендорские манифесты (KM/BPM) И файловая
система ME инициализирована**. Проверка, которая её закроет: `1.bin` / `2.rom` —
профиль 0, манифестов нет, но UEP заполнен (ME работал). По гипотезе ECFinder
скажет `BG0`, по «состоянию ME» — `BG5`, по «маскам дескриптора» — тоже `BG5`
(у них те же `0x00F/0x00A`, что у Z-дампа).

Важно для строки в панели: **сам номер профиля (3/4/5) ECFinder не читает** — он
печатает двухзначный вердикт («настроен/нет»). Номер при этом в образе есть
(CDMD-JSON, раздел выше), и ECFinder его просто не смотрит: `image_BG4.bin`
(профиль 4) по нашей гипотезе получит у него `BG0`, как соседний `image_BG3` —
различие 4 против 0 на вердикт не влияет, поскольку он идёт в паре с состоянием
файловой системы ME. Это **предсказание, не проверенное** — прогон ECFinder по
`image_BG4` его закрывает.

## Что ещё не разобрано (честно)

- **По чему именно ECFinder решает «настроен/нет».** Три кандидата дают разные
  предсказания для `1.bin` (см. выше) — прогон ECFinder по нему и по двум копиям с
  переставленными масками дескриптора (`/tmp/eomexp/…`) закрывает вопрос.
- **Область CDMD разобрана не полностью.** Опознаны подпись `FIT AS A FIDDLE`,
  адрес блока конфигурации и ключ `BtGuardProfileConfig`; остальные записи того же
  блока (сколько их, есть ли среди них настройки EOM) не перечислены. Стоит снять
  список всех JSON-ключей по всем дампам — это и есть карта настроек, читаемых из
  образа.
- **Номер профиля читается** (CDMD-JSON), но **для образов без блока CDMD не
  читается** — на них остаются только вторичные признаки (манифесты, UEP).
- **Флаги политики внутри Boot Policy Manifest.** Манифест разобран приложением
  только по версии, revision и SVN (`Packages/UEFIImage/.../FITComponents.swift`);
  где в его заголовке лежат биты политики и как они соответствуют профилям 3/4/5 —
  не установлено, и без платы с уровнем 3 или 4 не установится.
- **Семантика полей записи UEP**: адрес/размер окна (в Z-дампе 0x79ED80 и
  0x180000 — окно внутри BIOS-региона), 32-битная сумма 0xCAFC7A36, ключ Manifest
  ID. Формально MFIT пишет `BtGuardKeyManifestId = 0x1`, и `01 00 00 00` в записи
  ему соответствует.
- **Ключевая таблица MFS против UEP**: хеш лежит 12 раз — 6 записей в таблице
  MFS и 6 в UEP, и одна только эта таблица (48 записей по 48 байт) даёт понять,
  что ключевых входов несколько. Что именно она перечисляет (шесть раз один и тот
  же хеш с разными назначениями?) и зачем в UEP шесть копий, не доказано.
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
