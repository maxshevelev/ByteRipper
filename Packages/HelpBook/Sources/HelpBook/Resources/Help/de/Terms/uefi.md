@source-sha e1de2461e3f9d0b69938f23e33e1fa4c58ead11e40bdfb0e7eccf828e2c20c45
@term flash-descriptor
@name Flash Descriptor
@short Die ersten `0x1000` Bytes eines Intel-Flash-Images: die Karte des Chips.

Der Descriptor liegt ganz am Anfang des Dumps und sagt, wo jede [[term:region|Region]] beginnt und endet, welche Master sie lesen oder beschreiben dürfen und wie die Straps des Chips gesetzt sind.

Er ist die einzige Struktur hier mit echter Hersteller-Dokumentation — beschrieben in Intels Programming Guides zum Chipsatz —, was dem Panel hier mehr als Reverse Engineering unter die Füße legt.

Am Arbeitsplatz schaut man zuerst hierher: ist der Descriptor beschädigt, ist jede Adresse danach unzuverlässig, und die Platine startet meist gar nicht.

@see term:region
@see topic:tool-uefi

@term region
@name Region
@short Ein Bereich des Flash auf oberster Ebene, vom Descriptor festgelegt.

Der Descriptor teilt den Chip in Regionen — Descriptor, BIOS, ME, GbE, PDR, EC und weitere —, jede mit Anfangs- und Endadresse. Eine Region ist die Einheit, die am Arbeitsplatz üblicherweise zwischen Images wandert: jede ist ein für sich geschlossenes Format.

@see term:flash-descriptor
@see term:bios-region
@see term:me-region

@term bios-region
@name BIOS-Region
@short Die Firmware, die der Prozessor ausführt: Volumes, Dateien und Sektionen.

Die größte Region der meisten Images. In ihr liegen [[term:volume|Firmware-Volumes]] und darin die [[term:ffs-file|Dateien]] und [[term:section|Sektionen]], aus denen die UEFI-Firmware besteht: Startcode, Setup-Bildschirme, Treiber.

Das ist die Region, die ein Firmware-Update ersetzt, und die, um die es bei den meisten BIOS-Reparaturen geht.

@see term:volume
@see topic:tool-uefi

@term me-region
@name ME-Region
@short Intel-Management-Engine-Firmware — das Betriebssystem eines eigenen Prozessors, in einer eigenen Region.

Die ME (auf neueren Plattformen CSME) ist ein kleiner eigenständiger Prozessor im Chipsatz mit eigener Firmware, die in einer eigenen Region desselben Flash-Chips liegt. Sie läuft vor und neben der Haupt-CPU und kümmert sich um Energieverwaltung, Provisioning und Sicherheitsfunktionen.

Mit dem Code des BIOS selbst hat sie nichts zu tun und ist ein völlig anderes Format — deshalb hat ByteRipper dafür ein [[topic:tool-me|eigenes Panel]].

! Die ME prüft ihre eigene Firmware, bevor sie sie ausführt. Eine von Hand geänderte ME-Region ergibt keine geänderte Engine, sondern eine Platine, die hängt oder im Takt neu startet.

@see topic:tool-me
@see topic:recipe-me-check

@term gbe-region
@name GbE-Region
@short Die Konfiguration des integrierten Netzwerk-Controllers — mitsamt der MAC-Adresse der Platine.

Klein und platinenspezifisch. Wer die GbE-Region eines Spenders übernimmt, übernimmt dessen MAC-Adresse.

@see topic:recipe-board-data

@term pdr-region
@name PDR-Region
@short „Platform Data Region“ — ein Bereich, den der Platinenhersteller für Eigenes nutzen darf.

Was darin steht, hängt ganz am Hersteller. Behandeln Sie sie als möglicherweise platinenspezifisch: hat der Spender eine und Sie auch, vergleichen Sie beide, bevor Sie überschreiben.

@see topic:recipe-board-data

@term ec-region
@name EC-Region
@short Firmware für den Embedded Controller — den kleinen Chip für Tastatur, Lüfter, Akku und Einschaltsequenz.

In Notebooks liegt die EC-Firmware mal als eigene Region im selben SPI-Chip wie das BIOS, mal in einem eigenen Chip. Eine Platine, die gar nicht angeht oder sofort wieder ausgeht, ist häufiger ein EC- als ein BIOS-Problem.

@term volume
@name Firmware-Volume (FV)
@short Ein Container in der BIOS-Region, der Dateien enthält. Sein Header beginnt mit `_FVH`.

Ein Firmware-Volume ist die Einheit, auf der das Dateisystem der Firmware aufbaut. Eine BIOS-Region enthält meist mehrere: ein Boot-Block-Volume, ein oder mehrere Haupt-Volumes, ein NVRAM-Volume.

Der Header eines Volumes nennt seine Länge und seine eigene Prüfsumme, und der Platz hinter der letzten Datei ist sein **freier Speicher** — daran sieht man, wie viel noch hineinpasst.

@see term:ffs-file
@see term:free-space

@term ffs-file
@name FFS-Datei
@short Eine Datei in einem Firmware-Volume, identifiziert über eine [[term:guid|GUID]].

Dateien sind das, was ein Volume enthält. Jede hat eine GUID statt eines Namens, einen Typ (Treiber, Anwendung, Rohdaten, Volume-Abbild) und einen Header mit eigenen Prüfsummen. In einer Datei liegen [[term:section|Sektionen]].

Eine Zeile mit lesbarem Namen wie „DxeCore“ ist eine FFS-Datei, deren GUID der [[topic:databases|Katalog]] kennt.

@see term:section
@see term:pad-file

@term pad-file
@name Füll-Datei
@short Eine Datei, die es nur gibt, damit die nächste echte Datei dort beginnt, wo sie soll.

Eine GUID hat sie nur, weil jeder Datei-Header eine hat — in der Regel lauter Einsen —, und sie benennt nichts. Sie zu übergehen kostet nichts.

@term section
@name Sektion
@short Ein Teil einer FFS-Datei: ihr Code, ihr Name, ihre Version oder ein ganzes weiteres Volume.

Eine Datei besteht aus Sektionen, und Sektionen können ineinander liegen. Die üblichen sind das ausführbare Abbild (PE32), eine komprimierte Sektion (in der wieder Sektionen stecken), eine Oberflächensektion (der lesbare Name der Datei) und eine Versionssektion.

Eine **komprimierte Sektion** kann ByteRipper entpackt öffnen — das Panel klappt sie auf und zeigt, was wirklich darin steckt.

@see topic:fragments

@term free-space
@name Freier Speicher
@short Der unbeschriebene Rest eines Volumes hinter seiner letzten Datei.

Das Panel führt ihn mit Absicht auf: daran sieht man, ob noch ein Modul in ein Volume passt, und seine Größe ist eine schnelle Probe darauf, dass das Längenfeld des Volumes stimmt.

@see term:padding

@term padding
@name Padding
@short Raum zwischen Strukturen, in den nie jemand geschrieben hat.

Gelöschtes Padding ist die Füllmasse eines Dumps — meist `FF`. Der Baum blendet es aus, bis Sie danach fragen: ein großer Dump ist voll davon, und eine Zeile, hinter der nichts steht, ist eine Zeile zum Vorbeiscrollen.

Padding, das **Daten enthält**, wird immer aufgeführt: da liegt etwas, ob der Parser es versteht oder nicht.

@see term:free-space

@term nvram
@name NVRAM
@short Wo die Firmware ihre Einstellungen zwischen zwei Starts ablegt: Setup-Optionen, Boot-Reihenfolge, Secure-Boot-Schlüssel.

NVRAM liegt in einem eigenen Bereich der BIOS-Region, in einem Format, das vom Firmware-Hersteller abhängt. ByteRipper liest die gängigen — [[term:vss|VSS/VSS2]], FTW, EVSA, FDC und einige herstellereigene — und führt die Variablen darin auf.

Am Arbeitsplatz zählt NVRAM aus zwei Gründen: man kann ihn meist gefahrlos vom Spender übernehmen (die Firmware baut sich neu auf, was sie braucht), und seine Beschädigung ist eine häufige Ursache für eine Platine, die am Herstellerlogo hängt oder bei jedem Start ihre Einstellungen vergisst.

@see term:vss
@see topic:recipe-board-data

@term vss
@name VSS / VSS2
@short Das häufigste NVRAM-Format: ein Speicher benannter Variablen.

Jeder Eintrag ist eine Variable mit Namen (`BootOrder`, `PK`, `Setup`), Hersteller-GUID und Wert. ByteRipper benennt die Zeile nach dem Variablennamen statt nach der GUID: viele Variablen teilen sich eine Hersteller-GUID.

Im selben Bereich finden sich verwandte Speicher: **FTW** (der Eintrag eines fehlertoleranten Schreibvorgangs — das Journal, das ein Variablen-Update einen Stromausfall überstehen lässt), **EVSA**, **FDC**, **CMDB** und herstellereigene Flash-Maps. Das sind die Antworten verschiedener Hersteller auf dieselbe Aufgabe.

@see term:nvram

@term slic
@name SLIC / MSDM
@short OEM-Lizenzdaten von Windows, in der Firmware abgelegt.

Eine ACPI-Tabelle, die die Firmware veröffentlicht, damit ein vorinstalliertes Windows ohne Schlüssel aktiviert. Auf älteren Maschinen ist das SLIC, auf neueren MSDM. Die Daten hängen an Platine und Lizenz: mit denen eines Spenders überschrieben, aktiviert die Maschine unter Umständen nicht mehr.

@see topic:recipe-board-data

@term capsule
@name Capsule
@short Eine Update-Datei in einer Hülle, kein rohes Chip-Abbild.

Ein beim Hersteller geladenes Firmware-Update ist oft eine Capsule: das Image plus ein Header, der sagt, was womit aktualisiert wird. ByteRipper liest durch die Hülle hindurch und zeigt, was darin steckt.

Öffnet sich eine Datei als Capsule, denken Sie daran: das ist ein **Update**, kein Dump, und es muss nicht jede Region enthalten, die der Chip hat.

@term microcode
@name Microcode-Update
@short Ein Patch für den Prozessor selbst, geladen vor jedem Firmware-Code.

Intel legt Microcode-Updates in das Firmware-Image. Der Prozessor lädt sehr früh im Start das zu seiner Signatur passende — über die [[term:fit|FIT]].

Jedes Update trägt in seinem Header die CPU-Signatur, eine Revisionsnummer und ein Datum; danach benennt ByteRipper sie.

@see term:fit
@see topic:recipe-microcode

@term fit
@name FIT (Firmware Interface Table)
@short Eine Tabelle dessen, was der Prozessor laden muss, bevor er BIOS-Code ausführt.

Die FIT wird über einen Zeiger an einer festen Adresse nahe der oberen Flash-Grenze gefunden. Ihre Einträge zeigen — mit absoluten Adressen — auf [[term:microcode|Microcode-Updates]], ACMs, Boot-Guard-Manifeste und Policy-Einträge.

Weil die Adressen absolut sind, darf sich nichts bewegen, worauf eine FIT zeigt. Ein FIT-Eintrag, der in gelöschten Flash zeigt, ist eine Platine, die gar nicht erst startet.

@see topic:tool-fit
@see topic:recipe-microcode

@term boot-guard
@name Boot Guard
@short Eine Hardware-Prüfung, dass Teile der Firmware vom Platinenhersteller signiert sind.

Auf einer Plattform mit gesetztem Boot Guard prüft der Prozessor ein signiertes Manifest über deklarierte Flash-Bereiche, bevor er irgendetwas davon ausführt. Diese **geschützten Bereiche** sind im Image benannt, und das [[topic:tool-uefi|UEFI-Panel]] zählt sie in seiner Übersichtszeile.

! Bytes innerhalb eines geschützten Bereichs lassen sich nicht ändern. Die Signatur passt dann nicht mehr, und ohne den privaten Schlüssel des Herstellers lässt sie sich nicht neu berechnen. Kein Werkzeug behebt das; genau das ist der Sinn der Sache.

@see topic:bench-safety

@term top-swap
@name Top Swap
@short Eine Chipsatz-Funktion, die eine zweite Kopie des Boot-Blocks einblendet, wenn die erste versagt.

Die Platine hält zwei Boot-Blöcke, und ein Chipsatz-Bit entscheidet, welchen der Prozessor sieht. Das ist ein Wiederherstellungsmechanismus: ein missglücktes Beschreiben der einen Kopie kann überlebbar sein.

Am Arbeitsplatz gut zu wissen, weil ein Image damit berechtigterweise zwei fast gleiche Boot-Blöcke enthalten kann — und ein Vergleich zeigt beide.

@see topic:tool-fit

@term vscc
@name VSCC-Tabelle
@short Die Liste der Flash-Chips, die der Descriptor anzusteuern weiß.

„Vendor Specific Component Capabilities“: je unterstütztem Chip die Befehle und Zeiten, die der Chipsatz mit ihm verwenden soll. Wurde eine Platine mit einem Flash-Chip repariert, dessen ID nicht in dieser Tabelle steht, funktioniert das Beschreiben „von innen“ womöglich nicht — ein externer Programmer schon.

@see term:flash-descriptor

@term non-uefi-data
@name Nicht-UEFI-Daten
@short Bytes im Image, die der Parser als keine bekannte Struktur erkennt.

Kein Fehler. Hersteller legen ständig Eigenes in Firmware-Images, und ein EC-Image oder ein Option-ROM innerhalb einer BIOS-Region ist ein Format für sich.

Es ist aber die Stelle, an der man nachsieht, wenn etwas nicht aufgeht: eine Region, die Volumes sein sollte und sich als Nicht-UEFI-Daten liest, ist eine beschädigte Region.

@see topic:tool-zones
