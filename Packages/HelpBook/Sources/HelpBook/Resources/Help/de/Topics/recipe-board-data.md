@source-sha a6d1214ac94a2c757c1ce1a16668f46c776da63744bb60d2392e24eeede07996
# Platinenspezifische Daten bewahren

> Ein Spender-Image trägt die Identität des Spenders. Das sind die Bytes, die Ihre bleiben müssen.

Fast jeder Dump enthält ein wenig Daten, die **genau dieser Platine** gehören und keiner anderen. Schreiben Sie ein Spender-Image roh, verschieben Sie die Identität des Spenders auf Ihre Platine.

## Was üblicherweise platinenspezifisch ist

- **Die [[term:gbe-region|GbE-Region]]** — die Konfiguration des integrierten Netzwerk-Controllers und damit die **MAC-Adresse**. Zwei Platinen mit einer MAC-Adresse im selben Netz sind ein Fehler, der Tage später auffällt.
- **Maschinen-UUID und Seriennummern**, die der Hersteller in einem DMI/SMBIOS-Bereich innerhalb der BIOS-Region hält. Manche Firmware startet mit leeren Werten nicht oder landet in einem Wiederherstellungszustand.
- **Die Konfiguration der [[term:me-region|ME-Region]]** — siehe [[topic:recipe-me-check|Eine ME-Region prüfen]]. In der ME liegen platinenspezifische Einstellungen, und auf vielen Plattformen auch die Werte, die der Hersteller im Werk provisioniert hat.
- **NVRAM / [[term:vss|VSS]]-Speicher** — gesicherte Setup-Variablen, Boot-Einträge, hinterlegte Secure-Boot-Schlüssel. Meist gefahrlos vom Spender zu übernehmen (die Firmware baut sich neu auf, was sie braucht), aber nicht immer: manche Hersteller legen dort Lizenz- oder Konfigurationsdaten ab.
- **OEM-Lizenzdaten von Windows** ([[term:slic|SLIC]] / MSDM) auf älteren Maschinen.

## Wie man es macht

1. Öffnen Sie das Spender-Image und Ihr eigenes ursprüngliches Lesen nebeneinander.
2. Finden Sie jeden der obigen Bereiche im [[topic:tool-uefi|UEFI-Panel]] — GbE-Region und ME-Region sind Zeilen der obersten Ebene, ihre Offsets stehen in der Detailansicht.
3. [[topic:bookmarks|Setzen Sie ein Lesezeichen]] auf den Anfang jedes Bereichs. Beide Bereiche zeigen die Markierungen auf derselben Höhe — genau das braucht man hier.
4. Kopieren Sie jeden Bereich **aus Ihrem eigenen Dump** und setzen Sie ihn in das Spender-Image ein — schlichtes ⌘V überschreibt, es verschiebt sich also nichts.
5. Vergleichen Sie das Ergebnis ein letztes Mal mit Ihrem Dump und lesen Sie jeden verbliebenen Unterschied.

! Tun Sie das vor dem Schreiben, nicht danach. Sobald der Chip MAC und UUID des Spenders trägt, gibt es Ihre eigenen nur noch in der Datei, die Sie in Schritt 1 gesichert haben — deshalb lautet [[topic:bench-safety|die erste Regel]], dieses Lesen zu bewahren.
