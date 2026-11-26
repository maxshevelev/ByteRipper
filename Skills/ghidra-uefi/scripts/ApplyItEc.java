// The EC pass: an ITE EC firmware image (module kind EC, family ite-nds32)
// made ready for a review, before Ghidra's analysis.
//
//   analyzeHeadless <project> <name> -import <image> -processor NDS32:LE:32:default
//       -loader BinaryLoader -loader-baseAddr 0 -preScript ApplyItEc.java <ec-layout.json>
//
// The server (GhidraHost.createEC) reads the image's layout in Swift
// (Packages/ECImage) and writes it, with the register and interrupt maps of
// Skills/ghidra-ec/reference, into the JSON this script reads. The script
// only applies it:
//
// - blocks: `flash` [0, extent) r-x, `ram` rw, `regs` rw volatile;
// - functions at the vectors: ResetEntry, Exc_<name>, Isr_Lvl<N> (N is the
//   level the stub loads into r0: vector 9 + N); IsrCommonEntry, the level
//   handlers IsrLevelHandler<N>, IsrDispatch, and one Isr_Irq<NNN> per INTC
//   interrupt (a handler several interrupts share: Isr_IrqShared_<lowest>);
// - labels: Signature, VersionString, DataInitSource/DataInitTarget,
//   IsrLevelTable, IsrIrqTable, main, the registers with data of their width,
//   and the module's known labels.
//
// Nothing semantic beyond that: what a handler does is the review's. The
// last line it prints, `ApplyItEc done`, is what the server checks for.

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;

import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;

import ghidra.app.cmd.disassemble.DisassembleCommand;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.address.AddressSet;
import ghidra.program.model.address.AddressSpace;
import ghidra.program.model.data.ArrayDataType;
import ghidra.program.model.data.ByteDataType;
import ghidra.program.model.data.DWordDataType;
import ghidra.program.model.data.DataType;
import ghidra.program.model.data.DataUtilities;
import ghidra.program.model.data.PointerDataType;
import ghidra.program.model.data.StringDataType;
import ghidra.program.model.data.WordDataType;
import ghidra.program.model.listing.CommentType;
import ghidra.program.model.listing.Function;
import ghidra.program.model.mem.Memory;
import ghidra.program.model.mem.MemoryBlock;
import ghidra.program.model.symbol.SourceType;
import ghidra.program.model.symbol.SymbolTable;

public class ApplyItEc extends GhidraScript {
    private AddressSpace space;
    private int functions = 0;
    private int labels = 0;

    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length < 1) throw new IllegalArgumentException("ApplyItEc.java <ec-layout.json>");
        JsonObject input = JsonParser.parseString(Files.readString(Path.of(args[0]))).getAsJsonObject();
        space = currentProgram.getAddressFactory().getDefaultAddressSpace();
        Memory memory = currentProgram.getMemory();

        // The blocks.
        long extent = input.get("extent").getAsLong();
        MemoryBlock flash = memory.getBlock(at(input.get("flash_base").getAsLong()));
        if (flash == null) throw new IllegalStateException("no block at the flash base");
        flash.setName("flash");
        flash.setRead(true);
        flash.setWrite(false);
        flash.setExecute(true);
        if (flash.getSize() != extent) {
            println("ApplyItEc: the flash block is " + flash.getSize() + " bytes, the extent " + extent);
        }
        JsonArray ram = input.getAsJsonArray("ram");
        MemoryBlock ramBlock = memory.createUninitializedBlock("ram", at(ram.get(0).getAsLong()),
            ram.get(1).getAsLong() - ram.get(0).getAsLong(), false);
        ramBlock.setRead(true);
        ramBlock.setWrite(true);
        ramBlock.setExecute(false);
        JsonArray regs = input.getAsJsonArray("regs");
        MemoryBlock regBlock = memory.createUninitializedBlock("regs", at(regs.get(0).getAsLong()),
            regs.get(1).getAsLong() - regs.get(0).getAsLong(), false);
        regBlock.setRead(true);
        regBlock.setWrite(true);
        regBlock.setExecute(false);
        regBlock.setVolatile(true);

        // The header.
        long signature = input.get("signature").getAsLong();
        long version = input.get("version").getAsLong();
        label(signature, "Signature");
        if (signature != version) {
            data(signature, new ArrayDataType(ByteDataType.dataType, 16, 1));
        }
        label(version, "VersionString");
        // Exactly the printable run (ECChipFamily.version): a terminated
        // string would run on over the code that follows it (0xA0 on IT8227E).
        int versionLength = has(input, "version_length") ? input.get("version_length").getAsInt() : 0;
        if (versionLength > 0) data(version, new StringDataType(), versionLength);

        JsonObject layout = input.getAsJsonObject("layout");
        JsonObject startup = layout.has("startup") && layout.get("startup").isJsonObject()
            ? layout.getAsJsonObject("startup") : null;
        if (startup != null) {
            if (has(startup, "dataSource")) {
                label(startup.get("dataSource").getAsLong(), "DataInitSource");
                label(startup.get("dataTarget").getAsLong(), "DataInitTarget");
                int length = startup.get("dataLength").getAsInt();
                data(startup.get("dataSource").getAsLong(), new ArrayDataType(ByteDataType.dataType, length, 1));
            }
        }

        // The vectors and what they reach.
        for (JsonElement each : layout.getAsJsonArray("vectors")) {
            JsonObject vector = each.getAsJsonObject();
            int index = vector.get("index").getAsInt();
            label(index * 4L, String.format("Vector_%02d", index));
            function(vector.get("target").getAsLong(), vector.get("name").getAsString(), null);
        }
        if (startup != null && has(startup, "main")) function(startup.get("main").getAsLong(), "main", null);
        if (has(layout, "commonEntry")) {
            function(layout.get("commonEntry").getAsLong(), "IsrCommonEntry",
                "The entry every interrupt level's stub jumps to, with its level in r0: it calls the level's "
                + "handler from IsrLevelTable.");
        }
        if (has(layout, "levelTable")) {
            label(layout.get("levelTable").getAsLong(), "IsrLevelTable");
            for (JsonElement each : layout.getAsJsonArray("levelHandlers")) {
                JsonObject handler = each.getAsJsonObject();
                data(handler.get("slot").getAsLong(), PointerDataType.dataType);
                function(handler.get("target").getAsLong(), "IsrLevelHandler" + handler.get("number").getAsInt(), null);
            }
        }
        if (has(layout, "dispatcher")) {
            function(layout.get("dispatcher").getAsLong(), "IsrDispatch",
                "Reads the INTC's vector register (IVCT) and calls the handler of interrupt IVCT - 0x10 "
                + "from IsrIrqTable.");
        }
        JsonObject sources = input.has("irq_sources") ? input.getAsJsonObject("irq_sources") : new JsonObject();
        if (has(layout, "irqTable")) {
            label(layout.get("irqTable").getAsLong(), "IsrIrqTable");
            Map<Long, List<Integer>> byTarget = new TreeMap<>();
            for (JsonElement each : layout.getAsJsonArray("irqHandlers")) {
                JsonObject handler = each.getAsJsonObject();
                data(handler.get("slot").getAsLong(), PointerDataType.dataType);
                byTarget.computeIfAbsent(handler.get("target").getAsLong(), k -> new ArrayList<>())
                    .add(handler.get("number").getAsInt());
            }
            for (Map.Entry<Long, List<Integer>> entry : byTarget.entrySet()) {
                List<Integer> irqs = entry.getValue();
                int first = irqs.get(0);
                String plate;
                String name;
                if (irqs.size() == 1) {
                    name = String.format("Isr_Irq%03d", first);
                    String source = sources.has(String.valueOf(first)) ? sources.get(String.valueOf(first)).getAsString() : null;
                    plate = "INTC interrupt " + first
                        + (source != null ? ", source " + source + " (the register map's IT83XX_IRQ_" + source + ")" : "")
                        + ".";
                } else {
                    name = String.format("Isr_IrqShared_%03d", first);
                    StringBuilder list = new StringBuilder();
                    for (int irq : irqs) list.append(list.length() == 0 ? "" : ", ").append(irq);
                    plate = "The handler of " + irqs.size() + " INTC interrupts: " + list + ".";
                }
                function(entry.getKey(), name, plate);
            }
        }

        // The registers.
        int registers = 0;
        if (input.has("registers")) {
            for (JsonElement each : input.getAsJsonArray("registers")) {
                JsonObject register = each.getAsJsonObject();
                long address = register.get("address").getAsLong();
                if (!regBlock.contains(at(address))) continue;
                if (getSymbolAt(at(address)) != null && getSymbolAt(at(address)).getSource() == SourceType.IMPORTED) continue;
                label(address, register.get("name").getAsString());
                int width = register.get("width").getAsInt();
                DataType type = width == 4 ? DWordDataType.dataType : width == 2 ? WordDataType.dataType : ByteDataType.dataType;
                data(address, type);
                String note = register.get("block").getAsString()
                    + (register.has("description") ? ": " + register.get("description").getAsString() : "");
                currentProgram.getListing().setComment(at(address), CommentType.EOL, note);
                registers++;
            }
        }

        if (input.has("known_labels")) {
            for (JsonElement each : input.getAsJsonArray("known_labels")) {
                JsonObject known = each.getAsJsonObject();
                label(known.get("address").getAsLong(), known.get("name").getAsString());
            }
        }
        // The flash past the extent the code points at: the same code the
        // owner's `/v1/ec/reapply` runs on a project made before it was here.
        JsonObject flashRefs = flashReferences(currentProgram, input);
        labels += flashRefs.getAsJsonArray("labels_added").size();
        for (JsonElement each : flashRefs.getAsJsonArray("plates_kept")) {
            println("ApplyItEc: no plate at " + each.getAsJsonObject().get("address").getAsString() + ": "
                    + each.getAsJsonObject().get("why").getAsString());
        }
        // Calls into bytes the analysis left undecoded: a `jral5` through a
        // register the code builds with sethi/ori, whose target the analysis
        // only learns as a reference once the data laid above no longer
        // covers it (0xA0, called from ResetEntry on IT8227E).
        seedCallTargets(memory);
        println("ApplyItEc done: " + functions + " functions, " + labels + " labels, " + registers + " registers");
    }

    /**
     * The flash past the image extent the code points at, from the input's
     * `extent`, `host_update_size` and `refs_past_extent` (the server finds
     * the references in Swift, ECImage's `referencesPastExtent`): a DATA
     * reference from each `from`, so `xrefs` finds the code that uses it; a
     * `FlashRef_<ADDR>` label, no type; and a plate saying what is known of
     * it. Run by this script as a module is made, and by the owner
     * (`/v1/ec/reapply`) on a project made before it was part of that, in
     * the caller's transaction.
     *
     * It only adds: a reference that is there is not added again, a name a
     * place already has (a reviewer's `EflashState_2A600`) is kept, and so is
     * a plate. The answer lists each reference, label and plate added or
     * kept, a kept one with `why`.
     */
    public static JsonObject flashReferences(ghidra.program.model.listing.Program program, JsonObject input) {
        AddressSpace space = program.getAddressFactory().getDefaultAddressSpace();
        var references = program.getReferenceManager();
        SymbolTable symbols = program.getSymbolTable();
        var listing = program.getListing();
        long extent = input.get("extent").getAsLong();
        long hostUpdate = has(input, "host_update_size") ? input.get("host_update_size").getAsLong() : 0;
        JsonObject answer = new JsonObject();
        JsonArray refsAdded = new JsonArray(), refsKept = new JsonArray();
        JsonArray labelsAdded = new JsonArray(), labelsKept = new JsonArray();
        JsonArray platesAdded = new JsonArray(), platesKept = new JsonArray();
        java.util.Set<Long> placed = new java.util.HashSet<>();
        JsonArray given = has(input, "refs_past_extent") ? input.getAsJsonArray("refs_past_extent") : new JsonArray();
        for (JsonElement each : given) {
            long address = each.getAsJsonObject().get("address").getAsLong();
            long from = each.getAsJsonObject().get("from").getAsLong();
            Address to = space.getAddress(address);
            Address source = space.getAddress(from);
            JsonObject reference = new JsonObject();
            reference.addProperty("from", String.format("0x%X", from));
            reference.addProperty("address", String.format("0x%X", address));
            boolean there = false;
            for (var held : references.getReferencesFrom(source)) there |= held.getToAddress().equals(to);
            if (there) {
                reference.addProperty("why", "the reference is there");
                refsKept.add(reference);
            } else {
                references.addMemoryReference(source, to, ghidra.program.model.symbol.RefType.DATA,
                    SourceType.IMPORTED, ghidra.program.model.listing.CodeUnit.MNEMONIC);
                refsAdded.add(reference);
            }
            if (!placed.add(address)) continue;

            String name = String.format("FlashRef_%X", address);
            JsonObject label = new JsonObject();
            label.addProperty("address", String.format("0x%X", address));
            var primary = symbols.getPrimarySymbol(to);
            if (primary != null && !primary.isDynamic()) {
                label.addProperty("name", primary.getName());
                label.addProperty("why", primary.getName().equals(name) ? "the label is there"
                    : "the place is named " + primary.getName() + ": the name is kept");
                labelsKept.add(label);
            } else {
                try {
                    symbols.createLabel(to, name, SourceType.IMPORTED).setPrimary();
                    label.addProperty("name", name);
                    labelsAdded.add(label);
                } catch (Exception e) {
                    label.addProperty("why", "no label: " + e.getMessage());
                    labelsKept.add(label);
                }
            }

            JsonObject plate = new JsonObject();
            plate.addProperty("address", String.format("0x%X", address));
            String held = null;
            try {
                held = listing.getComment(CommentType.PLATE, to);
            } catch (Exception e) {
                held = null;
            }
            if (held != null && !held.isEmpty()) {
                plate.addProperty("why", "the place has a plate: it is kept");
                platesKept.add(plate);
                continue;
            }
            try {
                // Only what this module's bytes and family say: the plate
                // is keyed by the module and shows in every dump.
                String rewrite = hostUpdate > 0 && address < hostUpdate
                    ? String.format(" A host update (host_update_size 0x%X) rewrites [0x%X, 0x%X) from the host's copy.", hostUpdate, extent, hostUpdate)
                    : " Outside the range a host update rewrites.";
                listing.setComment(to, CommentType.PLATE, String.format(
                    "Referenced past the image extent (0x%X): the EC's flash data area, not part of this module."
                    + " Its contents are whatever the EC wrote there at run time.%s"
                    + " The meaning comes from the code that reads or writes it.", extent, rewrite));
                platesAdded.add(plate);
            } catch (Exception e) {
                plate.addProperty("why", "no plate: " + e.getMessage());
                platesKept.add(plate);
            }
        }
        answer.add("references_added", refsAdded);
        answer.add("references_kept", refsKept);
        answer.add("labels_added", labelsAdded);
        answer.add("labels_kept", labelsKept);
        answer.add("plates_added", platesAdded);
        answer.add("plates_kept", platesKept);
        return answer;
    }

    private void seedCallTargets(Memory memory) throws Exception {
        java.util.Set<Address> targets = new java.util.TreeSet<>();
        var references = currentProgram.getReferenceManager().getReferenceIterator(currentProgram.getMinAddress());
        while (references.hasNext()) {
            var reference = references.next();
            if (!reference.getReferenceType().isCall()) continue;
            Address target = reference.getToAddress();
            MemoryBlock block = memory.getBlock(target);
            if (block == null || !block.isExecute() || !block.isInitialized()) continue;
            if (getInstructionAt(target) != null || getDataContaining(target) != null) continue;
            targets.add(target);
        }
        // `sethi rX,hi; ori rX,rX,lo; jral5 rX`: the call target is
        // hi << 12 | lo. The analysis makes no reference of it when the
        // target was not code, so the call is found here and referenced.
        var instructions = currentProgram.getListing().getInstructions(true);
        while (instructions.hasNext()) {
            var call = instructions.next();
            if (!call.getMnemonicString().startsWith("jral")) continue;
            var low = call.getPrevious();
            var high = low == null ? null : low.getPrevious();
            if (low == null || high == null || !low.getMnemonicString().equals("ori")
                || !high.getMnemonicString().equals("sethi")) continue;
            Object[] target = call.getOpObjects(0);
            Object[] lowOps = low.getOpObjects(0), lowSource = low.getOpObjects(1), highOps = high.getOpObjects(0);
            if (target.length != 1 || lowOps.length != 1 || lowSource.length != 1 || highOps.length != 1
                || !target[0].equals(lowOps[0]) || !target[0].equals(lowSource[0]) || !target[0].equals(highOps[0])) continue;
            var hi = high.getScalar(1);
            var lo = low.getScalar(2);
            if (hi == null || lo == null) continue;
            Address to;
            try {
                to = at((hi.getUnsignedValue() << 12) | lo.getUnsignedValue());
            } catch (Exception e) {
                continue;
            }
            MemoryBlock block = memory.getBlock(to);
            if (block == null || !block.isExecute() || !block.isInitialized()) continue;
            boolean referenced = false;
            for (var each : call.getReferencesFrom()) referenced |= each.getToAddress().equals(to);
            if (!referenced) {
                currentProgram.getReferenceManager().addMemoryReference(call.getAddress(), to,
                    ghidra.program.model.symbol.RefType.COMPUTED_CALL, SourceType.ANALYSIS, 0);
            }
            if (getInstructionAt(to) == null && getDataContaining(to) == null) targets.add(to);
        }
        for (Address target : targets) {
            if (getInstructionAt(target) == null) {
                new DisassembleCommand(new AddressSet(target), null, true).applyTo(currentProgram, monitor);
            }
            if (getInstructionAt(target) != null && getFunctionAt(target) == null
                && currentProgram.getFunctionManager().getFunctionContaining(target) == null) {
                if (createFunction(target, null) != null) functions++;
            }
        }
    }

    private static boolean has(JsonObject object, String key) {
        return object.has(key) && !object.get(key).isJsonNull();
    }

    private Address at(long offset) {
        return space.getAddress(offset);
    }

    private void label(long offset, String name) throws Exception {
        SymbolTable symbols = currentProgram.getSymbolTable();
        symbols.createLabel(at(offset), name, SourceType.IMPORTED).setPrimary();
        labels++;
    }

    private void data(long offset, DataType type) {
        try {
            DataUtilities.createData(currentProgram, at(offset), type, -1,
                DataUtilities.ClearDataMode.CLEAR_ALL_UNDEFINED_CONFLICT_DATA);
        } catch (Exception e) {
            println("ApplyItEc: no " + type.getName() + " at 0x" + Long.toHexString(offset) + ": " + e.getMessage());
        }
    }

    private void data(long offset, DataType type, int length) {
        try {
            DataUtilities.createData(currentProgram, at(offset), type, length,
                DataUtilities.ClearDataMode.CLEAR_ALL_UNDEFINED_CONFLICT_DATA);
        } catch (Exception e) {
            println("ApplyItEc: no " + type.getName() + " at 0x" + Long.toHexString(offset) + ": " + e.getMessage());
        }
    }

    private void function(long offset, String name, String plate) throws Exception {
        Address entry = at(offset);
        if (getInstructionAt(entry) == null) {
            new DisassembleCommand(new AddressSet(entry), null, true).applyTo(currentProgram, monitor);
        }
        Function function = getFunctionAt(entry);
        if (function == null) function = createFunction(entry, name);
        if (function == null) {
            label(offset, name);
            println("ApplyItEc: no function at 0x" + Long.toHexString(offset) + " (" + name + ")");
            return;
        }
        function.setName(name, SourceType.IMPORTED);
        if (plate != null) function.setComment(plate);
        functions++;
    }
}
