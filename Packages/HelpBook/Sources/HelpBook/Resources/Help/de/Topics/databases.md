@source-sha a422849b1676eaf25b124788a60980093ddbd180e97b5b584e0d394a6a259117
# Die Online-Kataloge

> Vier öffentliche Kataloge, die Kennungen aus einem Dump mit Namen versehen. Ohne Zugriff auf sie ist das Programm voll funktionsfähig, zeigt die zusätzlichen Angaben aber nicht an.

Ein Teil dessen, was die Werkzeugbereiche zeigen, steht gar nicht in der Datei — es ist ein Name, den die Gemeinschaft einer Kennung gegeben hat, die die Datei trägt. Dafür lädt ByteRipper über HTTPS vier öffentliche Kataloge und prüft jeden höchstens einmal täglich auf eine neuere Fassung:

- **UEFI-GUID-Namen** — aus dem UEFITool-Projekt. Sie sind es, die das [[topic:tool-uefi|UEFI-Werkzeug]] statt einer nackten [[term:guid|GUID]] „AmiBoardInfo“ oder „DxeCore“ anzeigen lassen.
- **CPU-Microcode** — aus der Sammlung CPUMicrocodes. Danach werden die Microcode-Updates benannt, die das [[topic:tool-fit|FIT-Werkzeug]] auflistet: nach CPU-Signatur, Revision und Datum. Aus ihr stammt auch die Liste, die **Microcode hinzufügen…** anbietet.
- **ME-Firmware-Datenbank** — aus dem Projekt ME Analyzer. Mit ihr kann das [[topic:tool-me|ME-Werkzeug]] angeben, welchem bekannten Firmware-Release ein Image entspricht.
- **Intel-Prozessoren nach CPUID** — aus dem Repository IntelCPUID. Danach benennt das [[topic:tool-fit|FIT-Werkzeug]] die Prozessoren hinter jeder CPUID eines Microcodes, und diese Tabelle durchsucht die [[topic:cpuid-lookup|Intel-CPUID-Suche]]. Die letzte vollständig gelesene Kopie wird aufbewahrt und ohne Netzwerk verwendet.

## Was Tatsache ist und was ein Name

Die Werkzeuge halten die beiden Dinge auseinander:

- **Die Bytes gehören der Datei.** Eine Adresse, eine Größe, ein Versionsfeld, eine Prüfsumme werden alle aus dem Image selbst gelesen.
- **Der Name gehört dem Katalog.** Er ist eine Zuordnung der Gemeinschaft, er kann fehlen, und er kann falsch sein.

Eine Zeile „AmiBoardInfo · 0x7A0000 · 0x12C0“ heißt also: *die Datei hat an dieser Adresse tatsächlich ein Modul dieser Größe, und der Katalog sagt, dass diese GUID üblicherweise AmiBoardInfo heißt*.

## Ohne Netz

Keine Funktion des Programms benötigt das Netz. Ohne Verbindung oder bei geblocktem Abruf zeigen die Werkzeuge Kennungen statt Namen und melden nichts weiter: keine Dialoge und keine wiederholten Versuche. Alles, was aus den Bytes gelesen wird, bleibt davon unberührt.

Die Abrufe gehen an feste Adressen dieser Kataloge, und eine Anfrage enthält nichts aus der geöffneten Datei: Das Programm lädt einen Katalog vollständig herunter und gleicht ihn erst auf dem Rechner mit dem Dump ab.

Daher werden weder die Bytes des Images noch die darin gefundenen Kennungen übertragen. Der Dump verlässt die Maschine nicht.

Einmal am Tag prüft das Programm außerdem, ob eine neuere Fassung von ihm selbst erschienen ist. Das ist das fünfte und letzte, wofür es ans Netz geht.
