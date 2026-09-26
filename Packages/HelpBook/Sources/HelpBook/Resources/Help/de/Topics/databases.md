@source-sha e4cf6d4a2eec07b13eeeb9a1ca2079b5ae7daa949fb37259fc3d5df3c030e0ef
# Die Online-Kataloge

> Drei öffentliche Listen, die Zahlen im Dump in Namen verwandeln. Ohne sie läuft das Programm.

Ein Teil dessen, was die Werkzeugbereiche zeigen, steht gar nicht in der Datei — es ist ein Name, den die Gemeinschaft einer Kennung gegeben hat, die die Datei trägt. Dafür lädt ByteRipper über HTTPS drei öffentliche Kataloge und behält jeden einen Tag:

- **UEFI-GUID-Namen** — aus dem UEFITool-Projekt. Sie machen aus einer nackten [[term:guid|GUID]] im [[topic:tool-uefi|UEFI-Panel]] ein „AmiBoardInfo“ oder „DxeCore“.
- **CPU-Microcode** — aus der Sammlung CPUMicrocodes. Damit werden die Microcode-Updates benannt, die das [[topic:tool-fit|FIT-Panel]] auflistet: welche CPU-Signatur, welche Revision, welches Datum.
- **ME-Firmware-Datenbank** — aus dem „ME Analyzer“-Projekt. Mit ihr kann das [[topic:tool-me|ME-Panel]] sagen, welchem bekannten Firmware-Release ein Image entspricht.

## Was Tatsache ist und was ein Name

Diese Unterscheidung zählt am Arbeitsplatz, und die Panels halten sie:

- **Die Bytes gehören der Datei.** Ein Offset, eine Größe, ein Versionsfeld, eine Prüfsumme — alles aus dem Image vor Ihnen gelesen.
- **Der Name gehört dem Katalog.** Er ist eine Zuordnung der Gemeinschaft, er kann fehlen, und er kann falsch sein.

Eine Zeile „AmiBoardInfo · 0x7A0000 · 0x12C0“ heißt also: *die Datei hat an dieser Adresse tatsächlich ein Modul dieser Größe, und der Katalog sagt, dass diese GUID üblicherweise AmiBoardInfo heißt*.

## Ohne Netz

Nichts am Programm braucht das Netz. Ohne Verbindung — oder wenn der Abruf geblockt ist — zeigen die Panels Kennungen statt Namen und sagen sonst nichts dazu: keine Dialoge, keine Wiederholungen im Weg. Alles, was aus den Bytes gelesen wird, bleibt davon unberührt.

Nichts über Ihre Datei wird irgendwohin geschickt. Das sind Lesezugriffe auf öffentliche Listen; der Dump verlässt die Maschine nicht.

Einmal am Tag prüft das Programm außerdem, ob eine neuere Fassung von ihm selbst erschienen ist. Das ist das vierte und letzte, wofür es ans Netz geht.
