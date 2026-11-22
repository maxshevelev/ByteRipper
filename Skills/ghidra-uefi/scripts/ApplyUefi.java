// Give an analyzed UEFI module the names and types its source had.
//
//   analyzeHeadless ... -postScript ApplyUefi.java <uefi.gdt> <guids.tsv> <pei|dxe> \
//                       -postScript ExportCode.java out.json
//
// Ghidra reads a PEIM or a DXE driver as anonymous code: FUN_0000f6e0,
// param_2, (**(code **)(lVar1 + 0x58))(). What a reader needs is what EDK2
// wrote — gBS->LocateProtocol (&gEfiPciIoProtocolGuid, NULL, &PciIo). Most of it
// can be recovered from the structure the specifications fix, without guessing:
//
//  1. Every 16 bytes that are a GUID the catalogue names become an EFI_GUID
//     called by that name (gEfiPciIoProtocolGuid).
//  2. The entry point gets the signature the phase defines: ImageHandle and
//     SystemTable for a DXE driver, FileHandle and PeiServices for a PEIM.
//  3. Those types follow the arguments: a function called with SystemTable or
//     PeiServices gets that parameter's type, and so on down the calls.
//  4. A global written from them is named and typed: gST, gBS, gRT,
//     gImageHandle, gSmst — the names the EDK2 libraries use.
//  5. With those types, a call through a service table names its field. A
//     LocateProtocol, HandleProtocol, OpenProtocol or LocatePpi gives its
//     result the protocol's type and name; an InstallProtocolInterface or an
//     InstallPpi names the interface it installs; a NotifyPpi, CreateEventEx or
//     RegisterProtocolNotify names the function it registers.
//  6. A function that hands DEBUG a "%a" format and an identifier is named by
//     that identifier: EDK2 passes __FUNCTION__ there.
//
// Every name this pass gives is SourceType.ANALYSIS, and why it was given is
// kept in the program's "ByteRipper.nameReason" property, which ExportCode
// writes beside the name: a reader sees which names are the module's own
// evidence and which are Ghidra's FUN_ placeholders.
//
// <uefi.gdt> is `uefi_X64.gdt` or `uefi_Ia32.gdt` (BuildUefiTypes.java);
// <guids.tsv> is `<32 hex digits of the GUID's bytes>\t<name>` per line, the
// names with their g…Guid spelling (the server's `UEFITypes` writes it).
// @category ByteRipper

import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Deque;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Iterator;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.data.DataType;
import ghidra.program.model.data.DataTypeConflictHandler;
import ghidra.program.model.data.DataTypeManager;
import ghidra.program.model.data.DataUtilities;
import ghidra.program.model.data.FileDataTypeManager;
import ghidra.program.model.data.FunctionDefinition;
import ghidra.program.model.data.ParameterDefinition;
import ghidra.program.model.data.ParameterDefinitionImpl;
import ghidra.program.model.data.VoidDataType;
import ghidra.program.model.data.Pointer;
import ghidra.program.model.data.PointerDataType;
import ghidra.program.model.data.Structure;
import ghidra.program.model.data.DataTypeComponent;
import ghidra.program.model.data.TypeDef;
import ghidra.program.model.data.Undefined;
import ghidra.program.model.listing.Data;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Parameter;
import ghidra.program.model.listing.ParameterImpl;
import ghidra.program.model.mem.Memory;
import ghidra.program.model.mem.MemoryBlock;
import ghidra.program.model.pcode.HighFunction;
import ghidra.program.model.pcode.HighFunctionDBUtil;
import ghidra.program.model.pcode.HighParam;
import ghidra.program.model.pcode.HighSymbol;
import ghidra.program.model.pcode.HighVariable;
import ghidra.program.model.pcode.PcodeOp;
import ghidra.program.model.pcode.PcodeOpAST;
import ghidra.program.model.pcode.Varnode;
import ghidra.program.model.symbol.SourceType;
import ghidra.program.model.symbol.Symbol;
import ghidra.program.model.util.StringPropertyMap;

public class ApplyUefi extends GhidraScript {

    /// The property ExportCode reads a name's reason from.
    static final String REASON = "ByteRipper.nameReason";

    private FileDataTypeManager archive;
    private final Map<String, DataType> archiveTypes = new HashMap<>();
    private final Map<String, String> guidNames = new HashMap<>();
    private final Map<Address, String> guidAt = new HashMap<>();
    private StringPropertyMap reasons;
    private DecompInterface decompiler;
    private Function entry;
    private boolean pei;
    private int named, typedParameters, typedGlobals, typedLocals, typedReturns;
    /// Functions the pass leaves as they are: in a reviewed module, the
    /// library's links, which read as their registry entry's text.
    private final Set<Address> skip = new HashSet<>();

    /// The types that follow the arguments down the calls, and the global a
    /// value of that type is called by when the module keeps one.
    private static final Map<String, String> TRACKED = Map.of(
        "EFI_SYSTEM_TABLE*", "gST",
        "EFI_BOOT_SERVICES*", "gBS",
        "EFI_RUNTIME_SERVICES*", "gRT",
        "EFI_PEI_SERVICES**", "gPeiServices",
        "EFI_MM_SYSTEM_TABLE*", "gMmst",
        "EFI_SMM_SYSTEM_TABLE2*", "gSmst");

    private static final String ZERO_GUID = "0".repeat(32);
    private static final String ONES_GUID = "F".repeat(32);

    private static final Pattern IDENTIFIER = Pattern.compile("[A-Za-z_][A-Za-z0-9_]{2,63}");

    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length < 3) {
            println("usage: ApplyUefi.java <uefi.gdt> <guids.tsv> <pei|dxe> [retype]");
            return;
        }
        if (args.length > 3 && args[3].equals("retype")) {
            retype(new File(args[0]), new File(args[1]), args[2].equalsIgnoreCase("pei"), null);
            return;
        }
        pei = args[2].equalsIgnoreCase("pei");
        open(new File(args[0]), new File(args[1]));
        try {
            declareFirstPair("InstallMultipleProtocolInterfaces");
            declareFirstPair("UninstallMultipleProtocolInterfaces");
            dropThisCall();
            labelGuids();
            typeEntry();
            propagateParameters();
            nameGlobals();
            followServiceCalls();
            typeFromValues();
            nameFromDebugStrings();
            efiApiFunctionTypes();
            hexUint8();
        } finally {
            close();
        }
        println(String.format(
            "ApplyUefi: %d GUIDs, %d parameters, %d globals, %d locals, %d returns typed; %d functions named",
            guidAt.size(), typedParameters, typedGlobals, typedLocals, typedReturns, named));
        // The signatures and types set here schedule Ghidra's own analysis
        // again (stack frames, parameter ids). Run it to the end now, so what
        // the export reads in this run is the program a kept project saves:
        // the batch artifact and an owner's publish of the same program agree.
        analyzeChanges(currentProgram);
    }

    private void open(File gdt, File guids) throws Exception {
        archive = FileDataTypeManager.openFileArchive(gdt, false);
        Iterator<DataType> all = archive.getAllDataTypes();
        while (all.hasNext()) {
            DataType type = all.next();
            archiveTypes.putIfAbsent(type.getName(), type);
        }
        readGuids(guids);
        try {
            reasons = currentProgram.getUsrPropertyManager().createStringPropertyMap(REASON);
        } catch (Exception exists) {
            reasons = currentProgram.getUsrPropertyManager().getStringPropertyMap(REASON);
        }
        decompiler = new DecompInterface();
        decompiler.toggleCCode(false);
        decompiler.toggleSyntaxTree(true);
        decompiler.openProgram(currentProgram);
    }

    private void close() {
        if (decompiler != null) decompiler.dispose();
        decompiler = null;
        if (archive != null) archive.close();
        archive = null;
    }

    /// The typing steps again, on a program a review has worked on: what the
    /// pass types now that it did not when the module was created. It types
    /// only what is still untyped — `int`, `undefined`, `code *` — and never
    /// changes a name or a type a review set: a variable the review named
    /// keeps its name and gets the type. Nothing is renamed that a review
    /// named, no signature is replaced, no convention changed. The owner runs
    /// it in its program (`/v1/uefi/retype`) after `set(state, …)`; answers
    /// how many places it typed.
    public int retype(File gdt, File guids, boolean pei, Set<Address> skip) throws Exception {
        this.pei = pei;
        if (skip != null) this.skip.addAll(skip);
        open(gdt, guids);
        int undone = 0;
        try {
            Map<Function, Kept> kept = keep();
            findEntry();
            propagateParameters();
            nameGlobals();
            followServiceCalls();
            typeFromValues();
            undone = undoWhereReviewLost(kept);
        } finally {
            close();
        }
        int typed = Math.max(0, typedParameters + typedGlobals + typedLocals + typedReturns - undone);
        println(String.format("ApplyUefi retype: %d parameters, %d globals, %d locals, %d returns typed; "
            + "%d functions put back", typedParameters, typedGlobals, typedLocals, typedReturns, revertedFunctions));
        return typed;
    }

    /// A function as the review left it: what the database holds of its
    /// variables and return, and the names the review gave as the
    /// decompiler prints them, with their types.
    private record Kept(List<KeptVariable> locals, List<DataType> parameters, List<SourceType> parameterSources,
                        DataType returned, SourceType signatureSource, Map<String, DataType> reviewNames) { }

    private record KeptVariable(String name, ghidra.program.model.listing.VariableStorage storage, int firstUse,
                                DataType type, SourceType source) { }

    private int revertedFunctions = 0;

    /// Each global the pass typed, with the type it had (none: undefined).
    private final Map<Address, DataType> globalsBefore = new HashMap<>();

    private Map<Function, Kept> keep() {
        Map<Function, Kept> kept = new HashMap<>();
        for (Function function : currentProgram.getFunctionManager().getFunctions(true)) {
            if (monitor.isCancelled()) break;
            HighFunction high = decompile(function);
            if (high == null) continue;
            List<KeptVariable> locals = new ArrayList<>();
            for (ghidra.program.model.listing.Variable local : function.getLocalVariables()) {
                locals.add(new KeptVariable(local.getName(), local.getVariableStorage(), local.getFirstUseOffset(),
                    local.getDataType(), local.getSource()));
            }
            List<DataType> parameters = new ArrayList<>();
            List<SourceType> sources = new ArrayList<>();
            for (Parameter parameter : function.getParameters()) {
                parameters.add(parameter.getDataType());
                sources.add(parameter.getSource());
            }
            kept.put(function, new Kept(locals, parameters, sources, function.getReturnType(),
                function.getSignatureSource(), reviewNames(high)));
        }
        return kept;
    }

    /// The names a review gave the function's parameters and locals, as the
    /// decompiler prints them, with their types.
    private static Map<String, DataType> reviewNames(HighFunction high) {
        Map<String, DataType> names = new HashMap<>();
        Iterator<HighSymbol> symbols = high.getLocalSymbolMap().getSymbols();
        while (symbols.hasNext()) {
            HighSymbol symbol = symbols.next();
            Symbol held = symbol.getSymbol();
            if (held == null || held.getSource() != SourceType.USER_DEFINED) continue;
            names.put(symbol.getName(), symbol.getDataType());
        }
        return names;
    }

    /// Typing one place can make the decompiler read a function's frame
    /// anew: a review's name moves to another slot, or a type the review set
    /// gives way to one Ghidra guessed. A function whose review names lost
    /// that way is put back as the review left it, with what it calls when
    /// that is not enough, and the pass leaves it alone. Answers how many
    /// typed places were put back.
    private int undoWhereReviewLost(Map<Function, Kept> kept) {
        int undone = 0;
        Set<Function> putBack = new HashSet<>();
        for (int round = 0; round < 4 && !monitor.isCancelled(); round++) {
            decompiler.flushCache();
            Set<Function> lost = new HashSet<>();
            for (Map.Entry<Function, Kept> each : kept.entrySet()) {
                // Read even a function the pass now leaves alone: it is
                // the one being checked.
                DecompileResults results = decompiler.decompileFunction(each.getKey(), 60, monitor);
                HighFunction high = results != null && results.decompileCompleted() ? results.getHighFunction() : null;
                if (high == null) continue;
                if (reviewLost(each.getValue().reviewNames(), reviewNames(high))) {
                    lost.add(each.getKey());
                    if (round > 0) {
                        Map<String, DataType> now = reviewNames(high);
                        for (Map.Entry<String, DataType> name : each.getValue().reviewNames().entrySet()) {
                            DataType at = now.get(name.getKey());
                            if (at == null || name.getValue() != null && !at.isEquivalent(name.getValue())) {
                                println("ApplyUefi retype: still lost in " + each.getKey().getName() + ": "
                                    + name.getKey() + " " + (name.getValue() == null ? "?" : name.getValue().getDisplayName())
                                    + " -> " + (at == null ? "gone" : at.getDisplayName()));
                            }
                        }
                    }
                }
            }
            println("ApplyUefi retype: round " + round + ", review names lost in " + lost.size() + " functions");
            if (lost.isEmpty()) break;
            Set<Function> back = new HashSet<>(lost);
            // Later rounds, when that was not enough: what the function
            // calls typed it too, through the parameters and returns it
            // reads.
            if (round > 1) for (Function function : lost) back.addAll(function.getCalledFunctions(monitor));
            // A global the function reads, typed by the pass: a call through
            // it now has a signature, and the stack reads differently.
            if (round > 0) for (Function function : lost) undone += putBackGlobals(function);
            for (Function function : back) {
                Kept state = kept.get(function);
                if (state == null) continue;
                undone += putBack(function, state);
                skip.add(function.getEntryPoint());
                if (putBack.add(function)) {
                    revertedFunctions++;
                    println("ApplyUefi retype: put back " + function.getName() + " at " + function.getEntryPoint());
                }
            }
        }
        return undone;
    }

    /// Whether a review name is gone, or holds a type other than the one it
    /// had — unless it had none and now has an interface or table's type.
    private static boolean reviewLost(Map<String, DataType> before, Map<String, DataType> after) {
        for (Map.Entry<String, DataType> name : before.entrySet()) {
            DataType now = after.get(name.getKey());
            if (now == null) return true;
            DataType was = name.getValue();
            if (was == null || now.isEquivalent(was)) continue;
            if (untyped(was) && knownPointer(now)) continue;
            return true;
        }
        return false;
    }

    /// Puts back the globals the pass typed that the function refers to.
    private int putBackGlobals(Function function) {
        int changed = 0;
        ghidra.program.model.symbol.ReferenceManager references = currentProgram.getReferenceManager();
        for (Address at : function.getBody().getAddresses(true)) {
            for (ghidra.program.model.symbol.Reference reference : references.getReferencesFrom(at)) {
                Address target = reference.getToAddress();
                if (!globalsBefore.containsKey(target)) continue;
                DataType was = globalsBefore.remove(target);
                Data held = currentProgram.getListing().getDataAt(target);
                if (held == null || was != null && held.getDataType().isEquivalent(was)) continue;
                try {
                    currentProgram.getListing().clearCodeUnits(target, held.getMaxAddress(), false);
                    if (was != null) DataUtilities.createData(currentProgram, target, was, -1,
                        DataUtilities.ClearDataMode.CLEAR_ALL_UNDEFINED_CONFLICT_DATA);
                    changed++;
                    println("ApplyUefi retype: put back the global at " + target);
                } catch (Exception refused) {
                    println("ApplyUefi retype: could not put back the global at " + target + ": " + refused.getMessage());
                }
            }
        }
        return changed;
    }

    /// Puts the function's variables and return back as `state` holds them.
    /// Answers how many places changed back.
    private int putBack(Function function, Kept state) {
        int changed = 0;
        Map<String, KeptVariable> held = new HashMap<>();
        for (KeptVariable local : state.locals()) held.put(local.storage() + "@" + local.firstUse(), local);
        Set<String> present = new HashSet<>();
        for (ghidra.program.model.listing.Variable local : function.getLocalVariables()) {
            String key = local.getVariableStorage() + "@" + local.getFirstUseOffset();
            KeptVariable was = held.get(key);
            try {
                if (was == null) {
                    function.removeVariable(local);
                    changed++;
                    continue;
                }
                present.add(key);
                if (!local.getDataType().isEquivalent(was.type())) {
                    local.setDataType(was.type(), was.source());
                    changed++;
                }
                if (!local.getName().equals(was.name())) local.setName(was.name(), was.source());
            } catch (Exception refused) {
                println("ApplyUefi retype: could not put back " + local.getName() + " in " + function.getName()
                    + ": " + refused.getMessage());
            }
        }
        // A variable the typing replaced — Ghidra commits a retyped local as
        // a new one — comes back as it was.
        for (Map.Entry<String, KeptVariable> each : held.entrySet()) {
            if (present.contains(each.getKey())) continue;
            KeptVariable was = each.getValue();
            try {
                function.addLocalVariable(new ghidra.program.model.listing.LocalVariableImpl(
                    was.name(), was.firstUse(), was.type(), was.storage(), currentProgram), was.source());
                changed++;
            } catch (Exception refused) {
                println("ApplyUefi retype: could not bring back " + was.name() + " in " + function.getName()
                    + ": " + refused.getMessage());
            }
        }
        Parameter[] parameters = function.getParameters();
        for (int index = 0; index < parameters.length && index < state.parameters().size(); index++) {
            if (parameters[index].getDataType().isEquivalent(state.parameters().get(index))) continue;
            try {
                parameters[index].setDataType(state.parameters().get(index), state.parameterSources().get(index));
                changed++;
            } catch (Exception refused) {
                // As above.
            }
        }
        if (!function.getReturnType().isEquivalent(state.returned())) {
            try {
                function.setReturnType(state.returned(), state.signatureSource());
                changed++;
            } catch (Exception refused) {
                // As above.
            }
        }
        return changed;
    }

    // MARK: - Types and GUIDs

    /// A type from the archive, resolved into the program with what it needs.
    private DataType type(String name) {
        DataType type = archiveTypes.get(name);
        if (type == null) return null;
        return currentProgram.getDataTypeManager().resolve(type, DataTypeConflictHandler.DEFAULT_HANDLER);
    }

    private DataType pointer(DataType type, int depth) {
        DataTypeManager manager = currentProgram.getDataTypeManager();
        DataType result = type;
        for (int i = 0; i < depth; i++) result = new PointerDataType(result, manager);
        return result;
    }

    /// `EFI_SYSTEM_TABLE*`, `EFI_PEI_SERVICES**`: the name a type is tracked
    /// by, through pointers and the `_EFI_…` struct a typedef names.
    static String key(DataType type) {
        StringBuilder stars = new StringBuilder();
        while (type instanceof Pointer) {
            stars.append('*');
            type = ((Pointer) type).getDataType();
            if (type == null) return "";
        }
        String name = type.getName();
        if (name.startsWith("_")) name = name.substring(1);
        return name + stars;
    }

    private void readGuids(File file) throws Exception {
        try (BufferedReader reader = new BufferedReader(new FileReader(file))) {
            String line;
            while ((line = reader.readLine()) != null) {
                int tab = line.indexOf('\t');
                if (tab != 32) continue;
                guidNames.putIfAbsent(line.substring(0, 32).toUpperCase(), line.substring(tab + 1).trim());
            }
        }
    }

    /// Every four-byte-aligned 16 bytes the catalogue names, outside the
    /// instructions, becomes an EFI_GUID under that name.
    private void labelGuids() throws Exception {
        DataType guid = type("EFI_GUID");
        if (guid == null || guidNames.isEmpty()) return;
        Memory memory = currentProgram.getMemory();
        for (MemoryBlock block : memory.getBlocks()) {
            if (!block.isInitialized() || block.getSize() > (64L << 20)) continue;
            byte[] bytes = new byte[(int) block.getSize()];
            try {
                block.getBytes(block.getStart(), bytes);
            } catch (Exception error) {
                continue;
            }
            for (int at = 0; at + 16 <= bytes.length; at += 4) {
                String key = hex(bytes, at, 16);
                // All zeros is gEfiPartTypeUnusedGuid to EDK2 and gZeroGuid to
                // the catalogue — and is also every zeroed global. All ones is
                // erased flash. Neither is evidence of a GUID.
                if (key.equals(ZERO_GUID) || key.equals(ONES_GUID)) continue;
                String name = guidNames.get(key);
                if (name == null) continue;
                Address address = block.getStart().add(at);
                if (currentProgram.getListing().getInstructionContaining(address) != null) continue;
                try {
                    DataUtilities.createData(currentProgram, address, guid, -1,
                        DataUtilities.ClearDataMode.CLEAR_ALL_UNDEFINED_CONFLICT_DATA);
                } catch (Exception taken) {
                    continue;
                }
                if (label(address, name, "the GUID's bytes are " + name + " in the GUID catalogue")) {
                    guidAt.put(address, name);
                }
            }
        }
    }

    private static String hex(byte[] bytes, int at, int count) {
        StringBuilder builder = new StringBuilder(count * 2);
        for (int i = 0; i < count; i++) builder.append(String.format("%02X", bytes[at + i] & 0xFF));
        return builder.toString();
    }

    /// The GUID at an address: one the scan labelled, or 16 bytes the
    /// catalogue names (a GUID inside a structure the scan's alignment missed).
    private String guidName(Address address) {
        if (address == null) return null;
        String known = guidAt.get(address);
        if (known != null) return known;
        byte[] bytes = new byte[16];
        try {
            if (currentProgram.getMemory().getBytes(address, bytes) != 16) return null;
        } catch (Exception error) {
            return null;
        }
        String key = hex(bytes, 0, 16);
        return key.equals(ZERO_GUID) || key.equals(ONES_GUID) ? null : guidNames.get(key);
    }

    /// (Un)InstallMultipleProtocolInterfaces is `(Handle, ...)`: every pair
    /// after the handle is a variable argument, and the decompiler often
    /// shows none of them. Declaring the first pair keeps the protocol a
    /// call installs in the C; later pairs stay variable.
    private void declareFirstPair(String field) {
        DataType table = type("EFI_BOOT_SERVICES");
        DataType guid = type("EFI_GUID");
        while (table instanceof TypeDef) table = ((TypeDef) table).getBaseDataType();
        if (!(table instanceof Structure) || guid == null) return;
        FunctionDefinition definition = null;
        for (DataTypeComponent component : ((Structure) table).getComponents()) {
            if (!field.equals(component.getFieldName())) continue;
            DataType type = component.getDataType();
            while (type instanceof TypeDef || type instanceof Pointer) {
                type = type instanceof TypeDef ? ((TypeDef) type).getBaseDataType()
                                               : ((Pointer) type).getDataType();
            }
            if (type instanceof FunctionDefinition) definition = (FunctionDefinition) type;
        }
        if (definition == null) return;
        ParameterDefinition[] current = definition.getArguments();
        if (current.length != 1) return;
        DataTypeManager manager = currentProgram.getDataTypeManager();
        definition.setArguments(new ParameterDefinition[] {
            current[0],
            new ParameterDefinitionImpl("Protocol", pointer(guid, 1), "the first protocol's GUID"),
            new ParameterDefinitionImpl("Interface", new PointerDataType(VoidDataType.dataType, manager),
                "the first protocol's interface"),
        });
        definition.setVarArgs(true);
    }

    // MARK: - Names

    /// Names a place, unless something better than Ghidra's default already
    /// names it. Returns whether the name is now there.
    private boolean label(Address address, String name, String reason) {
        try {
            Symbol primary = currentProgram.getSymbolTable().getPrimarySymbol(address);
            if (primary != null && primary.getSource() != SourceType.DEFAULT) {
                return primary.getName().equals(name);
            }
            Symbol symbol = currentProgram.getSymbolTable().createLabel(address, unique(name),
                SourceType.ANALYSIS);
            symbol.setPrimary();
            reasons.add(address, reason);
            return true;
        } catch (Exception error) {
            return false;
        }
    }

    /// Names a function Ghidra left as FUN_…; a name the module or a user
    /// already gave is kept.
    private boolean name(Function function, String name, String reason) {
        if (function == null || function.getSymbol().getSource() != SourceType.DEFAULT) return false;
        try {
            function.setName(unique(name), SourceType.ANALYSIS);
            reasons.add(function.getEntryPoint(), reason);
            named++;
            return true;
        } catch (Exception error) {
            return false;
        }
    }

    /// `name`, or `name_2`, `name_3`… when a global of that name exists.
    private String unique(String name) {
        String candidate = name;
        for (int n = 2; !currentProgram.getSymbolTable().getGlobalSymbols(candidate).isEmpty(); n++) {
            candidate = name + "_" + n;
        }
        return candidate;
    }

    /// gEfiPciIoProtocolGuid → PciIo: what EDK2 calls a pointer to it.
    static String interfaceName(String guid) {
        String base = guid;
        if (base.startsWith("g")) base = base.substring(1);
        if (base.endsWith("Guid")) base = base.substring(0, base.length() - 4);
        if (base.startsWith("Efi") && base.length() > 3 && Character.isUpperCase(base.charAt(3))) {
            base = base.substring(3);
        }
        for (String suffix : new String[] { "Protocol", "Ppi" }) {
            if (base.endsWith(suffix) && base.length() > suffix.length()) {
                base = base.substring(0, base.length() - suffix.length());
            }
        }
        return base;
    }

    /// gEfiPciIoProtocolGuid → EFI_PCI_IO_PROTOCOL: the struct MdePkg declares
    /// for it, when the archive has one by that name.
    private DataType interfaceType(String guid) {
        String base = guid;
        if (base.startsWith("g")) base = base.substring(1);
        if (base.endsWith("Guid")) base = base.substring(0, base.length() - 4);
        StringBuilder snake = new StringBuilder();
        for (int i = 0; i < base.length(); i++) {
            char c = base.charAt(i);
            if (i > 0 && Character.isUpperCase(c)
                    && (Character.isLowerCase(base.charAt(i - 1)) || Character.isDigit(base.charAt(i - 1)))) {
                snake.append('_');
            }
            snake.append(Character.toUpperCase(c));
        }
        String name = snake.toString();
        DataType type = type(name);
        if (type == null && !name.startsWith("EFI_")) type = type("EFI_" + name);
        return type;
    }

    // MARK: - The entry point and the parameters

    private void findEntry() {
        for (Address address : currentProgram.getSymbolTable().getExternalEntryPointIterator()) {
            Function function = getFunctionAt(address);
            if (function != null) {
                entry = function;
                return;
            }
        }
        List<Function> named = getGlobalFunctions("entry");
        if (!named.isEmpty()) entry = named.get(0);
    }

    private void typeEntry() throws Exception {
        for (Address address : currentProgram.getSymbolTable().getExternalEntryPointIterator()) {
            Function function = getFunctionAt(address);
            if (function != null) {
                entry = function;
                break;
            }
        }
        // getFunction(String) is marked for removal in Ghidra 12.2; the
        // global functions by name are the same lookup.
        if (entry == null) {
            List<Function> named = getGlobalFunctions("entry");
            if (!named.isEmpty()) entry = named.get(0);
        }
        if (entry == null) return;
        DataType status = type("EFI_STATUS");
        Parameter first, second;
        if (pei) {
            DataType handle = type("EFI_PEI_FILE_HANDLE");
            DataType services = type("EFI_PEI_SERVICES");
            if (handle == null || services == null) return;
            first = new ParameterImpl("FileHandle", handle, currentProgram);
            second = new ParameterImpl("PeiServices", pointer(services, 2), currentProgram);
        } else {
            DataType handle = type("EFI_HANDLE");
            DataType table = type("EFI_SYSTEM_TABLE");
            if (handle == null || table == null) return;
            first = new ParameterImpl("ImageHandle", handle, currentProgram);
            second = new ParameterImpl("SystemTable", pointer(table, 1), currentProgram);
        }
        // EFIAPI: cdecl on IA32, the Microsoft x64 convention on X64. Ghidra
        // may have guessed __thiscall from an ECX use, which would put a
        // `this` in front of the two parameters.
        setEfiApi(entry);
        entry.replaceParameters(Function.FunctionUpdateType.DYNAMIC_STORAGE_FORMAL_PARAMS, true,
            SourceType.ANALYSIS, first, second);
        if (status != null) entry.setReturnType(status, SourceType.ANALYSIS);
        typedParameters += 2;
        name(entry, "_ModuleEntryPoint",
            "the image's entry point; EDK2 calls it _ModuleEntryPoint");
    }

    /// The archive's function types carry no convention — EFIAPI is a macro
    /// the parser drops — and a 32-bit program's default is the windows
    /// spec's __stdcall: an indirect call through a PEI service or a PPI
    /// member then read as taking its arguments off the stack, and the stack
    /// locals after it moved (issue 4a9a4484). EFIAPI is cdecl on IA32. The
    /// owner does the same at open and after each change.
    private void efiApiFunctionTypes() {
        if (currentProgram.getDefaultPointerSize() != 4
            || currentProgram.getCompilerSpec().getCallingConvention("__cdecl") == null) return;
        java.util.List<FunctionDefinition> unknown = new java.util.ArrayList<>();
        Iterator<DataType> types = currentProgram.getDataTypeManager().getAllDataTypes();
        while (types.hasNext()) {
            if (types.next() instanceof FunctionDefinition function
                && "unknown".equals(function.getCallingConventionName())) unknown.add(function);
        }
        for (FunctionDefinition function : unknown) {
            try {
                function.setCallingConvention("__cdecl");
            } catch (Exception error) {
                println("ApplyUefi: no cdecl for " + function.getPathName() + ": " + error);
            }
        }
        println("ApplyUefi: " + unknown.size() + " function types given EFIAPI (cdecl)");
    }

    /// EDK2's UINT8 — `unsigned char` — shown in hex (types revision 5), so
    /// the decompiler prints a byte's constants as numbers (`0x7f`), not
    /// characters (`'\x7f'`). Ghidra keeps a typedef's display format only in
    /// a program, never in an archive; the owner does the same at open and
    /// after each change.
    private void hexUint8() {
        List<DataType> found = new ArrayList<>();
        currentProgram.getDataTypeManager().findDataTypes("UINT8", found);
        ghidra.docking.settings.FormatSettingsDefinition format = ghidra.docking.settings.FormatSettingsDefinition.DEF;
        int set = 0;
        for (DataType type : found) {
            if (!(type instanceof ghidra.program.model.data.TypeDef def) || def.getLength() != 1
                || !(def.getBaseDataType() instanceof ghidra.program.model.data.UnsignedCharDataType)) continue;
            format.setChoice(def.getDefaultSettings(), ghidra.docking.settings.FormatSettingsDefinition.HEX);
            set++;
        }
        println("ApplyUefi: UINT8 shown in hex (" + set + ")");
    }

    /// Firmware is C: no function has a `this`. Ghidra guesses __thiscall
    /// for a 32-bit function that happens to read ECX, and then every call
    /// to it passes a `this` and every caller grows `extraout_ECX` values.
    /// A convention Ghidra guessed is put back to cdecl, EFIAPI on IA32; one
    /// a user or the image's own symbols set is kept.
    private void dropThisCall() {
        if (currentProgram.getDefaultPointerSize() != 4) return;
        int dropped = 0;
        for (Function function : currentProgram.getFunctionManager().getFunctions(true)) {
            if (!"__thiscall".equals(function.getCallingConventionName())) continue;
            if (function.getSignatureSource() == SourceType.USER_DEFINED
                    || function.getSignatureSource() == SourceType.IMPORTED) continue;
            try {
                function.setCallingConvention("__cdecl");
                dropped++;
            } catch (Exception unknown) {
                // No cdecl in this language; the guess stays.
            }
        }
        println("ApplyUefi: " + dropped + " __thiscall guesses set to __cdecl");
    }

    private void setEfiApi(Function function) {
        try {
            String convention = currentProgram.getDefaultPointerSize() == 4 ? "__cdecl"
                : currentProgram.getCompilerSpec().getDefaultCallingConvention().getName();
            function.setCallingConvention(convention);
        } catch (Exception unknown) {
            // The language has no such convention; Ghidra's stays.
        }
    }

    /// The variable an argument carries, through the casts and copies the
    /// decompiler puts between a typed parameter and a call: `(int *)PeiServices`.
    private static HighVariable carried(Varnode argument) {
        Varnode varnode = argument;
        for (int depth = 0; varnode != null && depth < 4; depth++) {
            HighVariable high = varnode.getHigh();
            if (high != null && isTracked(high)) return high;
            PcodeOp def = varnode.getDef();
            if (def == null || (def.getOpcode() != PcodeOp.CAST && def.getOpcode() != PcodeOp.COPY)) {
                return null;
            }
            varnode = def.getInput(0);
        }
        return null;
    }

    /// A value whose type follows the calls: a service table, or the image's
    /// own handle. Any EFI_HANDLE is not one — only the parameter the entry
    /// point's ImageHandle was handed down as.
    private static boolean isTracked(HighVariable high) {
        String key = key(high.getDataType());
        if (TRACKED.containsKey(key)) return true;
        return key.equals("EFI_HANDLE") && isImageHandle(high);
    }

    private static boolean isImageHandle(HighVariable high) {
        HighSymbol symbol = high.getSymbol();
        return symbol != null && symbol.isParameter() && "ImageHandle".equals(symbol.getName());
    }

    private HighFunction decompile(Function function) {
        if (function == null || function.isExternal() || function.isThunk()) return null;
        if (skip.contains(function.getEntryPoint())) return null;
        DecompileResults results = decompiler.decompileFunction(function, 60, monitor);
        return results != null && results.decompileCompleted() ? results.getHighFunction() : null;
    }

    /// A function called with SystemTable or PeiServices as an argument gets
    /// that parameter's type — and passes it on to what it calls in turn.
    private void propagateParameters() throws Exception {
        if (entry == null) return;
        Deque<Function> work = new ArrayDeque<>();
        Set<Function> queued = new HashSet<>();
        work.add(entry);
        queued.add(entry);
        while (!work.isEmpty() && !monitor.isCancelled()) {
            Function caller = work.poll();
            HighFunction high = decompile(caller);
            if (high == null) continue;
            Iterator<PcodeOpAST> ops = high.getPcodeOps();
            while (ops.hasNext()) {
                PcodeOpAST op = ops.next();
                if (op.getOpcode() != PcodeOp.CALL) continue;
                Function callee = getFunctionAt(op.getInput(0).getAddress());
                if (callee == null || callee.isThunk() || callee.isExternal()) continue;
                for (int slot = 1; slot < op.getNumInputs(); slot++) {
                    HighVariable argument = carried(op.getInput(slot));
                    if (argument == null) continue;
                    if (giveParameter(callee, slot - 1, argument)) {
                        typedParameters++;
                        if (queued.add(callee)) work.add(callee);
                    }
                }
            }
        }
    }

    /// Gives `callee`'s parameter `index` the type and name of the argument,
    /// when the callee's own parameter has no type yet.
    private boolean giveParameter(Function callee, int index, HighVariable argument) throws Exception {
        if (callee.getParameterCount() <= index) {
            HighFunction high = decompile(callee);
            if (high == null) return false;
            HighFunctionDBUtil.commitParamsToDatabase(high, true,
                HighFunctionDBUtil.ReturnCommitOption.NO_COMMIT, SourceType.ANALYSIS);
        }
        if (skip.contains(callee.getEntryPoint())) return false;
        Parameter parameter = callee.getParameter(index);
        if (parameter == null) return false;
        DataType current = parameter.getDataType();
        DataType wanted = argument.getDataType();
        if (key(current).equals(key(wanted))) return false;
        // A parameter a review named, or the image's symbols: its type only,
        // and only while it has none.
        if (parameter.getSource() == SourceType.USER_DEFINED || parameter.getSource() == SourceType.IMPORTED) {
            if (!untyped(current, parameter.getSource()) || current.getLength() != wanted.getLength()) return false;
            parameter.setDataType(wanted, parameter.getSource());
            return true;
        }
        if (!Undefined.isUndefined(current) && !(current instanceof Pointer
                && Undefined.isUndefined(((Pointer) current).getDataType()))
                && current.getLength() != wanted.getLength()) return false;
        parameter.setDataType(wanted, SourceType.ANALYSIS);
        HighSymbol symbol = argument.getSymbol();
        String name = symbol != null && symbol.isParameter() ? symbol.getName() : null;
        if (name != null && !name.startsWith("param_")) {
            try {
                parameter.setName(name, SourceType.ANALYSIS);
            } catch (Exception taken) {
                // Another parameter of the callee has that name.
            }
        }
        return true;
    }

    // MARK: - Globals

    /// A global written from SystemTable, BootServices, RuntimeServices, the
    /// image handle or the MM table is the one the EDK2 libraries keep.
    private void nameGlobals() throws Exception {
        for (Function function : currentProgram.getFunctionManager().getFunctions(true)) {
            if (monitor.isCancelled()) break;
            HighFunction high = decompile(function);
            if (high == null) continue;
            Iterator<PcodeOpAST> ops = high.getPcodeOps();
            while (ops.hasNext()) {
                PcodeOpAST op = ops.next();
                Varnode value;
                Address target;
                int code = op.getOpcode();
                // A write is a COPY to the global, a STORE through its
                // address, or — when a call follows that may read it — an
                // INDIRECT whose first input is the value written rather than
                // the global's own earlier value.
                if ((code == PcodeOp.COPY || code == PcodeOp.INDIRECT) && op.getOutput() != null
                        && op.getOutput().isAddress()
                        && !(op.getInput(0).isAddress()
                             && op.getInput(0).getAddress().equals(op.getOutput().getAddress()))) {
                    value = op.getInput(0);
                    target = op.getOutput().getAddress();
                } else if (op.getOpcode() == PcodeOp.STORE) {
                    value = op.getInput(2);
                    target = constantAddress(op.getInput(1));
                } else {
                    continue;
                }
                if (target == null || !currentProgram.getMemory().contains(target)) continue;
                HighVariable carriedValue = carried(value);
                if (carriedValue == null) continue;
                DataType type = carriedValue.getDataType();
                String name = TRACKED.get(key(type));
                String reason = name == null ? null
                    : "written from a " + key(type) + " value in " + function.getName();
                if (name == null && !pei && key(type).equals("EFI_HANDLE")
                        && isImageHandle(carriedValue)) {
                    name = "gImageHandle";
                    reason = "written from the ImageHandle the entry point was given, in "
                        + function.getName();
                }
                if (name == null || type == null) continue;
                if (typeGlobal(target, type, name, reason)) typedGlobals++;
            }
        }
    }

    private boolean typeGlobal(Address address, DataType type, String name, String reason) {
        Symbol primary = currentProgram.getSymbolTable().getPrimarySymbol(address);
        if (primary != null && primary.getSource() != SourceType.DEFAULT) {
            // Named already — by the review or this pass — so the name stays;
            // a place with no type yet still gets the type.
            Data held = currentProgram.getListing().getDataAt(address);
            if (held != null && held.isDefined() && !untyped(held.getDataType(), primary.getSource())) return false;
            if (held != null && held.getDataType().isEquivalent(type)) return false;
            return putData(address, type);
        }
        if (!putData(address, type)) {
            // The place could not take the type; its name still helps.
            return label(address, name, reason);
        }
        return label(address, name, reason);
    }

    /// Puts `type` at `address`. Data Ghidra's own analysis left there — an
    /// undefined, a pointer, a value of the same size — gives way; anything
    /// else (a structure, a string, a user's type) is kept.
    private boolean putData(Address address, DataType type) {
        if (!globalsBefore.containsKey(address)) {
            Data held = currentProgram.getListing().getDataAt(address);
            globalsBefore.put(address, held != null && held.isDefined() ? held.getDataType() : null);
        }
        try {
            DataUtilities.createData(currentProgram, address, type, -1,
                DataUtilities.ClearDataMode.CLEAR_ALL_UNDEFINED_CONFLICT_DATA);
            return true;
        } catch (Exception conflict) {
            Data existing = currentProgram.getListing().getDataAt(address);
            if (existing == null) return false;
            DataType held = existing.getDataType();
            boolean analysis = held instanceof Pointer || Undefined.isUndefined(held)
                || existing.getLength() == type.getLength() && !(held instanceof Structure);
            if (!analysis || existing.getLength() > type.getLength()) return false;
            try {
                currentProgram.getListing().clearCodeUnits(address,
                    address.add(Math.max(existing.getLength(), type.getLength()) - 1), false);
                DataUtilities.createData(currentProgram, address, type, -1,
                    DataUtilities.ClearDataMode.CLEAR_ALL_UNDEFINED_CONFLICT_DATA);
                return true;
            } catch (Exception still) {
                return false;
            }
        }
    }

    /// The address a varnode is a constant pointer to: `#0x1234`, or the
    /// decompiler's `PTRSUB(#0, #0x1234)`, through copies and casts.
    private Address constantAddress(Varnode varnode) {
        for (int depth = 0; varnode != null && depth < 6; depth++) {
            if (varnode.isConstant()) return safeAddress(varnode.getOffset());
            PcodeOp def = varnode.getDef();
            if (def == null) return null;
            int code = def.getOpcode();
            if (code == PcodeOp.COPY || code == PcodeOp.CAST) {
                varnode = def.getInput(0);
            } else if (code == PcodeOp.PTRSUB && def.getInput(0).isConstant()
                    && def.getInput(0).getOffset() == 0 && def.getInput(1).isConstant()) {
                return safeAddress(def.getInput(1).getOffset());
            } else {
                return null;
            }
        }
        return null;
    }

    private Address safeAddress(long offset) {
        try {
            Address address = toAddr(offset);
            return currentProgram.getMemory().contains(address) ? address : null;
        } catch (Exception error) {
            return null;
        }
    }

    // MARK: - Service calls

    /// The field of a service table a call goes through: `LocateProtocol` for
    /// `(*gBS->LocateProtocol)(…)`, `LocatePpi` for `(*(*PeiServices)->LocatePpi)(…)`.
    private String serviceField(PcodeOp call) {
        Varnode target = call.getInput(0);
        for (int depth = 0; target != null && depth < 4; depth++) {
            PcodeOp def = target.getDef();
            if (def == null) return null;
            if (def.getOpcode() == PcodeOp.COPY || def.getOpcode() == PcodeOp.CAST) {
                target = def.getInput(0);
                continue;
            }
            if (def.getOpcode() != PcodeOp.LOAD) return null;
            PcodeOp field = def.getInput(1).getDef();
            if (field == null) return null;
            if (field.getOpcode() != PcodeOp.PTRSUB && field.getOpcode() != PcodeOp.INT_ADD) return null;
            Varnode base = field.getInput(0);
            Varnode offset = field.getInput(1);
            if (!offset.isConstant() || base.getHigh() == null) return null;
            DataType type = base.getHigh().getDataType();
            if (!(type instanceof Pointer)) return null;
            DataType table = ((Pointer) type).getDataType();
            while (table instanceof TypeDef) table = ((TypeDef) table).getBaseDataType();
            if (!(table instanceof Structure)) return null;
            DataTypeComponent component = ((Structure) table).getComponentAt((int) offset.getOffset());
            return component == null ? null : component.getFieldName();
        }
        return null;
    }

    private void followServiceCalls() throws Exception {
        for (Function function : currentProgram.getFunctionManager().getFunctions(true)) {
            if (monitor.isCancelled()) break;
            HighFunction high = decompile(function);
            if (high == null) continue;
            // An event created in this function, for a notify registered here.
            Function createdCallback = null;
            Iterator<PcodeOpAST> ops = high.getPcodeOps();
            while (ops.hasNext()) {
                PcodeOpAST op = ops.next();
                if (op.getOpcode() != PcodeOp.CALLIND) continue;
                String field = serviceField(op);
                if (field == null) continue;
                switch (field) {
                    case "LocateProtocol":
                        consumed(high, op, 1, 3, "LocateProtocol");
                        break;
                    case "HandleProtocol":
                    case "OpenProtocol":
                        consumed(high, op, 2, 3, field);
                        break;
                    case "LocatePpi":
                        consumed(high, op, 2, 5, "LocatePpi");
                        break;
                    case "SmmLocateProtocol":
                    case "MmLocateProtocol":
                        consumed(high, op, 1, 3, field);
                        break;
                    case "SmmHandleProtocol":
                    case "MmHandleProtocol":
                        consumed(high, op, 2, 3, field);
                        break;
                    case "InstallProtocolInterface":
                        installed(op, 2, 4);
                        break;
                    case "InstallMultipleProtocolInterfaces":
                        for (int slot = 2; slot + 1 < op.getNumInputs(); slot += 2) installed(op, slot, slot + 1);
                        break;
                    case "InstallPpi":
                        descriptors(op, 2, false);
                        break;
                    case "NotifyPpi":
                        descriptors(op, 2, true);
                        break;
                    case "CreateEvent":
                        createdCallback = op.getNumInputs() > 3 ? functionAt(op.getInput(3)) : null;
                        break;
                    case "CreateEventEx":
                        if (op.getNumInputs() > 5) {
                            String group = guidName(constantAddress(op.getInput(5)));
                            Function callback = functionAt(op.getInput(3));
                            if (group != null && callback != null) {
                                name(callback, "On" + interfaceName(group),
                                    "CreateEventEx registers it for the " + group + " event group");
                            }
                        }
                        break;
                    case "RegisterProtocolNotify":
                        String guid = guidName(constantAddress(op.getInput(1)));
                        if (guid != null && createdCallback != null) {
                            name(createdCallback, "On" + interfaceName(guid) + "Installed",
                                "its event is the one RegisterProtocolNotify ties to " + guid);
                        }
                        break;
                    default:
                        break;
                }
            }
        }
    }

    /// The function a constant code pointer names. A callback only ever
    /// reached through a pointer may not be a function yet; it is made one
    /// when the address is executable code.
    private Function functionAt(Varnode varnode) {
        Address address = constantAddress(varnode);
        return address == null ? null : functionAtAddress(address);
    }

    private Function functionAtAddress(Address address) {
        Function function = getFunctionAt(address);
        if (function != null) return function;
        MemoryBlock block = currentProgram.getMemory().getBlock(address);
        if (block == null || !block.isExecute()) return null;
        try {
            if (currentProgram.getListing().getInstructionAt(address) == null) disassemble(address);
            return createFunction(address, null);
        } catch (Exception error) {
            return null;
        }
    }

    /// A protocol or PPI the module looks up: the out argument is typed as a
    /// pointer to it and named after it — a global gPciIo, a local PciIo.
    private void consumed(HighFunction high, PcodeOp call, int guidSlot, int outSlot, String service) {
        if (call.getNumInputs() <= outSlot) return;
        String guid = serviceGuid(call, guidSlot, service);
        if (guid == null) return;
        DataType iface = interfaceType(guid);
        DataType pointerType = iface == null ? null : pointer(iface, 1);
        String base = interfaceName(guid);
        String reason = service + " fills it with the " + guid + " interface";
        Address global = constantAddress(call.getInput(outSlot));
        if (global != null) {
            if (pointerType != null ? typeGlobal(global, pointerType, "g" + base, reason)
                                    : label(global, "g" + base, reason)) {
                typedGlobals++;
            }
            return;
        }
        PcodeOp reference = call.getInput(outSlot).getDef();
        if (reference == null || reference.getOpcode() != PcodeOp.PTRSUB) return;
        Address stack = HighFunctionDBUtil.getSpacebaseReferenceAddress(
            currentProgram.getAddressFactory(), reference);
        if (stack == null || !stack.isStackAddress()) return;
        HighSymbol local = high.getLocalSymbolMap().findLocal(stack, null);
        if (local == null) return;
        if (local.isNameLocked()) {
            if (pointerType != null && untyped(local.getDataType())) typeLocal(local, pointerType);
            return;
        }
        try {
            HighFunctionDBUtil.updateDBVariable(local, base,
                pointerType != null ? pointerType : local.getDataType(), SourceType.ANALYSIS);
            typedLocals++;
        } catch (Exception taken) {
            // The name is taken in this function, or the storage moved.
        }
    }

    /// The GUID a service call is handed. One the catalogue does not know is
    /// still a GUID — the service says so — and is typed and called
    /// gUnknownGuid_<Data1>, so its uses are one name and the panel says plainly
    /// that nobody has named it. Returns the catalogue's name, or null.
    private String serviceGuid(PcodeOp call, int slot, String service) {
        Address address = constantAddress(call.getInput(slot));
        String name = guidName(address);
        if (name != null || address == null) return name;
        byte[] bytes = new byte[16];
        try {
            if (currentProgram.getMemory().getBytes(address, bytes) != 16) return null;
        } catch (Exception error) {
            return null;
        }
        String key = hex(bytes, 0, 16);
        if (key.equals(ZERO_GUID) || key.equals(ONES_GUID)) return null;
        DataType guid = type("EFI_GUID");
        if (guid == null) return null;
        String data1 = String.format("%08X", (bytes[0] & 0xFFL) | (bytes[1] & 0xFFL) << 8
            | (bytes[2] & 0xFFL) << 16 | (bytes[3] & 0xFFL) << 24);
        if (typeGlobal(address, guid, "gUnknownGuid_" + data1,
                service + " is handed this GUID; the catalogue has no name for it")) {
            guidAt.put(address, "gUnknownGuid_" + data1);
        }
        return null;
    }

    /// An interface the module installs: typed and named mPciIo, for an
    /// interface in the module's own data.
    private void installed(PcodeOp call, int guidSlot, int interfaceSlot) {
        if (call.getNumInputs() <= interfaceSlot) return;
        String guid = serviceGuid(call, guidSlot, "InstallProtocolInterface");
        Address iface = constantAddress(call.getInput(interfaceSlot));
        if (guid == null || iface == null) return;
        DataType type = interfaceType(guid);
        String reason = "installed as the " + guid + " interface";
        if (type != null ? typeGlobal(iface, type, "m" + interfaceName(guid), reason)
                         : label(iface, "m" + interfaceName(guid), reason)) {
            typedGlobals++;
        }
    }

    /// An InstallPpi or NotifyPpi list: { Flags, Guid*, Ppi* or Notify } until
    /// the flag that ends the list. The descriptors are typed, the PPI named,
    /// the notify function named after what it waits for.
    private void descriptors(PcodeOp call, int listSlot, boolean notify) throws Exception {
        if (call.getNumInputs() <= listSlot) return;
        Address list = constantAddress(call.getInput(listSlot));
        if (list == null) return;
        int pointerSize = currentProgram.getDefaultPointerSize();
        DataType descriptor = type(notify ? "EFI_PEI_NOTIFY_DESCRIPTOR" : "EFI_PEI_PPI_DESCRIPTOR");
        Memory memory = currentProgram.getMemory();
        Address at = list;
        for (int index = 0; index < 32; index++) {
            long flags = pointerSize == 8 ? memory.getLong(at) : memory.getInt(at) & 0xFFFFFFFFL;
            Address guidPointer = pointerAt(at.add(pointerSize));
            Address second = pointerAt(at.add(2L * pointerSize));
            String guid = guidName(guidPointer);
            if (descriptor != null) putData(at, descriptor);
            if (guid != null && second != null) {
                if (notify) {
                    name(functionAtAddress(second), "On" + interfaceName(guid) + "Installed",
                        "NotifyPpi calls it when " + guid + " is installed");
                } else {
                    DataType type = interfaceType(guid);
                    String reason = "InstallPpi installs it as " + guid;
                    if (type != null ? typeGlobal(second, type, "m" + interfaceName(guid), reason)
                                     : label(second, "m" + interfaceName(guid), reason)) {
                        typedGlobals++;
                    }
                }
            }
            // EFI_PEI_PPI_DESCRIPTOR_TERMINATE_LIST
            if ((flags & 0x80000000L) != 0 || guidPointer == null) break;
            at = at.add(3L * pointerSize);
        }
    }

    private Address pointerAt(Address address) {
        try {
            long value = currentProgram.getDefaultPointerSize() == 8
                ? currentProgram.getMemory().getLong(address)
                : currentProgram.getMemory().getInt(address) & 0xFFFFFFFFL;
            return safeAddress(value);
        } catch (Exception error) {
            return null;
        }
    }

    // MARK: - Values that carry a type

    /// No type anyone chose: Ghidra's `undefined`, a plain integer of a
    /// pointer's size (`int`, `uint`, `longlong`), `code *`, `void *`, and
    /// pointers to those (`int *`, `undefined4 **`). An EDK2 typedef — `UINTN`, `UINT32` —
    /// was chosen, and so was any structure.
    /// `untyped` for a place someone may have typed: a `void *` a review
    /// chose stays — a slot one function hands to several lookups of
    /// different interfaces is `void *` on purpose.
    static boolean untyped(DataType type, SourceType source) {
        if (!untyped(type)) return false;
        return source != SourceType.USER_DEFINED || !voidPointer(type);
    }

    /// Whether a stack local is written only through its address, handed
    /// to exactly one call.
    private boolean filledByOneCall(HighSymbol local) {
        ghidra.program.model.listing.VariableStorage storage = local.getStorage();
        if (storage == null || !storage.isStackStorage()) return false;
        long offset = storage.getStackOffset();
        HighFunction high = local.getHighFunction();
        int calls = 0;
        Iterator<PcodeOpAST> ops = high.getPcodeOps();
        while (ops.hasNext()) {
            PcodeOpAST op = ops.next();
            if (op.getOpcode() != PcodeOp.CALL && op.getOpcode() != PcodeOp.CALLIND) continue;
            for (int index = 1; index < op.getNumInputs(); index++) {
                PcodeOp reference = op.getInput(index).getDef();
                while (reference != null && (reference.getOpcode() == PcodeOp.CAST || reference.getOpcode() == PcodeOp.COPY)) {
                    reference = reference.getInput(0).getDef();
                }
                if (reference == null || reference.getOpcode() != PcodeOp.PTRSUB) continue;
                Address stack = HighFunctionDBUtil.getSpacebaseReferenceAddress(currentProgram.getAddressFactory(), reference);
                if (stack != null && stack.isStackAddress() && stack.getOffset() == offset) calls++;
            }
        }
        if (calls != 1) return false;
        HighVariable variable = local.getHighVariable();
        if (variable == null) return true;
        for (Varnode instance : variable.getInstances()) {
            PcodeOp def = instance.getDef();
            if (def != null && def.getOpcode() != PcodeOp.INDIRECT && def.getOpcode() != PcodeOp.MULTIEQUAL) return false;
        }
        return true;
    }

    /// A pointer, at any depth, to `void`.
    static boolean voidPointer(DataType type) {
        DataType at = type;
        while (at instanceof TypeDef def) at = def.getBaseDataType();
        if (!(at instanceof Pointer)) return false;
        while (at instanceof Pointer pointer) at = pointer.getDataType();
        return at instanceof VoidDataType;
    }

    static boolean untyped(DataType type) {
        if (type == null) return true;
        if (Undefined.isUndefined(type) || type instanceof ghidra.program.model.data.DefaultDataType) return true;
        if (type instanceof Pointer pointer) {
            DataType target = pointer.getDataType();
            if (target == null) return true;
            if (target instanceof FunctionDefinition && "code".equals(target.getName())) return true;
            // `void *`: a pointer that says nothing of what it points to. It
            // gets a type only from a lookup's GUID or a call's signature.
            if (target instanceof VoidDataType) return true;
            return untyped(target);
        }
        // Ghidra's own `int`, `uint`, `longlong`: an EDK2 integer is a typedef.
        return !(type instanceof TypeDef) && type instanceof ghidra.program.model.data.AbstractIntegerDataType;
    }

    /// A type for a value the decompiler sees as one of the specifications'
    /// tables or interfaces: a pointer, at any depth, to a structure or a
    /// typedef of one from the EDK2 archive.
    /// Who named or typed a local: its database symbol's source, none for
    /// one only the decompiler made.
    private static SourceType source(HighSymbol local) {
        Symbol held = local.getSymbol();
        return held == null ? null : held.getSource();
    }

    private static boolean knownPointer(DataType type) {
        if (!(type instanceof Pointer)) return false;
        DataType at = type;
        while (at instanceof Pointer pointer) at = pointer.getDataType();
        if (at == null) return false;
        DataType base = at instanceof TypeDef def ? def.getBaseDataType() : at;
        if (!(base instanceof Structure)) return false;
        // A copy Ghidra made of a type two archives define differently is
        // nobody's type.
        if (at.getName().contains("conflict")) return false;
        ghidra.program.model.data.SourceArchive source = at.getSourceArchive();
        DataTypeManager manager = at.getDataTypeManager();
        ghidra.program.model.data.SourceArchive local = manager == null ? null : manager.getLocalSourceArchive();
        return source != null && (local == null || !source.getSourceArchiveID().equals(local.getSourceArchiveID()))
            && !source.getSourceArchiveID().equals(DataTypeManager.BUILT_IN_ARCHIVE_UNIVERSAL_ID);
    }

    /// Gives a local its type, keeping its name: a name the review locked
    /// stays locked.
    private boolean typeLocal(HighSymbol local, DataType type) {
        return typeLocal(local, type, null);
    }

    private boolean typeLocal(HighSymbol local, DataType type, String name) {
        if (local.isParameter()) return false;
        if (!untyped(local.getDataType())) return false;
        // A `void *` a review chose is kept unless one call fills it: a slot
        // the function hands to several lookups, or writes itself, holds
        // more than one interface.
        if (source(local) == SourceType.USER_DEFINED && voidPointer(local.getDataType())
                && !filledByOneCall(local)) return false;
        // A register local Ghidra would make holds its type from its first
        // use to the end of the function: every later value in that register
        // would take the type too. One the review already made is its own
        // range; a stack slot or a value the decompiler keys by hash is
        // exactly one variable.
        ghidra.program.model.listing.VariableStorage storage = local.getStorage();
        if (storage != null && storage.isRegisterStorage() && local.getSymbol() == null) return false;
        try {
            SourceType source = local.isNameLocked() ? SourceType.USER_DEFINED : SourceType.ANALYSIS;
            String given = local.isNameLocked() || name == null ? null : name;
            try {
                HighFunctionDBUtil.updateDBVariable(local, given, type, source);
            } catch (ghidra.util.exception.DuplicateNameException taken) {
                HighFunctionDBUtil.updateDBVariable(local, null, type, source);
            }
            typedLocals++;
            return true;
        } catch (Exception moved) {
            // The storage moved or the variable is not a single one.
            return false;
        }
    }

    /// Types a variable — a local, a parameter or a global — that holds no
    /// type yet. Answers whether it did.
    private boolean typeVariable(HighFunction high, HighVariable variable, DataType type) {
        return typeVariable(high, variable, type, null);
    }

    /// `name` is given to a local nobody named (`iVar1`); a name a review
    /// gave stays.
    private boolean typeVariable(HighFunction high, HighVariable variable, DataType type, String name) {
        if (variable == null || type == null || !untyped(variable.getDataType())) return false;
        if (variable.getDataType() != null && variable.getDataType().getLength() != type.getLength()
                && !Undefined.isUndefined(variable.getDataType())) return false;
        HighSymbol symbol = variable.getSymbol();
        if (symbol == null) return false;
        if (symbol.isGlobal()) {
            Address address = symbol.getStorage() != null && symbol.getStorage().isMemoryStorage()
                ? symbol.getStorage().getMinAddress() : null;
            if (address == null) return false;
            Symbol named = currentProgram.getSymbolTable().getPrimarySymbol(address);
            if (!untyped(variable.getDataType(), named == null ? null : named.getSource())) return false;
            if (!putData(address, type)) return false;
            typedGlobals++;
            return true;
        }
        if (symbol.isParameter()) {
            Function function = high.getFunction();
            int index = ((ghidra.program.model.pcode.HighParam) variable).getSlot();
            try {
                if (function.getParameterCount() <= index) {
                    HighFunctionDBUtil.commitParamsToDatabase(high, true,
                        HighFunctionDBUtil.ReturnCommitOption.NO_COMMIT, SourceType.ANALYSIS);
                }
                Parameter parameter = function.getParameter(index);
                if (parameter == null || !untyped(parameter.getDataType(), parameter.getSource())) return false;
                SourceType source = parameter.getSource() == SourceType.DEFAULT ? SourceType.ANALYSIS : parameter.getSource();
                parameter.setDataType(type, source);
                typedParameters++;
                return true;
            } catch (Exception refused) {
                return false;
            }
        }
        return typeLocal(symbol, type, name);
    }

    /// Typing that needs a typed value to start from, repeated while it finds
    /// more: each round's types are the next round's starting points.
    ///  - IA32 PEI: the PEI Services pointer kept below the IDT. A variable
    ///    the code reads 4 bytes below, in a function that executes SIDT, is
    ///    the IDT's base, `EFI_PEI_SERVICES ***`: `*IdtBase[-1]` is the table.
    ///  - An out argument of a call whose type is known: `&Smst` handed to
    ///    `GetSmstLocation (…, EFI_SMM_SYSTEM_TABLE2 **)` is the table,
    ///    `&Root` handed to `OpenVolume` the root directory's protocol.
    ///  - A variable copied from a value of a known table or interface type.
    ///  - A function whose every return is such a value returns that type,
    ///    `GetPeiServicesTablePointer` the pointer the IDT keeps.
    /// The service calls are followed again after each round, so a lookup
    /// through a table typed this round types its result too.
    private void typeFromValues() throws Exception {
        for (int round = 0; round < 4 && !monitor.isCancelled(); round++) {
            int before = typedParameters + typedGlobals + typedLocals + typedReturns;
            for (Function function : currentProgram.getFunctionManager().getFunctions(true)) {
                if (monitor.isCancelled()) break;
                HighFunction high = decompile(function);
                if (high == null) continue;
                boolean changed = pei && typeIdtBases(high);
                if (!changed) changed = typeOutArguments(high);
                if (!changed) changed = typeCopies(high);
                if (!changed) typeReturn(high);
            }
            if (typedParameters + typedGlobals + typedLocals + typedReturns == before) break;
            followServiceCalls();
        }
    }

    private boolean typeIdtBases(HighFunction high) {
        if (currentProgram.getDefaultPointerSize() != 4) return false;
        DataType services = type("EFI_PEI_SERVICES");
        if (services == null) return false;
        boolean sidt = false;
        Iterator<PcodeOpAST> ops = high.getPcodeOps();
        while (ops.hasNext()) {
            PcodeOpAST op = ops.next();
            if (op.getOpcode() != PcodeOp.CALLOTHER) continue;
            String name = currentProgram.getLanguage().getUserDefinedOpName((int) op.getInput(0).getOffset());
            // Stock Ghidra calls SIDT's operation `sidt`; the patched x86
            // language (descriptor-tables-1) reads it as the IDTR's two parts.
            if (name != null && (name.toLowerCase().contains("sidt")
                    || name.equals("InterruptDescriptorTableBase"))) sidt = true;
        }
        if (!sidt) return false;
        boolean changed = false;
        ops = high.getPcodeOps();
        while (ops.hasNext()) {
            PcodeOpAST op = ops.next();
            if (op.getOpcode() != PcodeOp.LOAD || op.getOutput() == null || op.getOutput().getSize() != 4) continue;
            PcodeOp address = op.getInput(1).getDef();
            while (address != null && (address.getOpcode() == PcodeOp.CAST || address.getOpcode() == PcodeOp.COPY)) {
                address = address.getInput(0).getDef();
            }
            if (address == null) continue;
            Varnode base = null;
            if (address.getOpcode() == PcodeOp.INT_ADD && address.getInput(1).isConstant()
                    && (address.getInput(1).getOffset() & 0xFFFFFFFFL) == 0xFFFFFFFCL) base = address.getInput(0);
            if (address.getOpcode() == PcodeOp.INT_SUB && address.getInput(1).isConstant()
                    && address.getInput(1).getOffset() == 4) base = address.getInput(0);
            if (address.getOpcode() == PcodeOp.PTRADD && address.getInput(1).isConstant()
                    && (address.getInput(1).getOffset() & 0xFFFFFFFFL) == 0xFFFFFFFFL) base = address.getInput(0);
            if (base == null || !fromIdtBase(base)) continue;
            // A variable that also holds other values — a register a review
            // named for one of them — is not the IDT's base.
            if (!everyValue(base.getHigh(), this::fromIdtBase)) continue;
            if (typeVariable(high, base.getHigh(), pointer(services, 3), "IdtBase")) changed = true;
        }
        return changed;
    }

    /// Whether a value is the IDT's base: the patched language's
    /// `InterruptDescriptorTableBase()`, or — stock Ghidra, whose `sidt`
    /// writes the descriptor to memory — four bytes read from a stack
    /// descriptor. Through copies, casts and the joins of branches.
    private boolean fromIdtBase(Varnode value) {
        Deque<Varnode> waiting = new ArrayDeque<>();
        Set<Varnode> seen = new HashSet<>();
        waiting.add(value);
        while (!waiting.isEmpty() && seen.size() < 32) {
            Varnode at = waiting.poll();
            if (!seen.add(at)) continue;
            PcodeOp def = at.getDef();
            if (def == null) continue;
            switch (def.getOpcode()) {
                case PcodeOp.COPY, PcodeOp.CAST, PcodeOp.INDIRECT -> waiting.add(def.getInput(0));
                case PcodeOp.MULTIEQUAL -> { for (Varnode input : def.getInputs()) waiting.add(input); }
                case PcodeOp.CALLOTHER -> {
                    String name = currentProgram.getLanguage().getUserDefinedOpName((int) def.getInput(0).getOffset());
                    if ("InterruptDescriptorTableBase".equals(name)) return true;
                }
                case PcodeOp.LOAD -> {
                    PcodeOp address = def.getInput(1).getDef();
                    while (address != null && (address.getOpcode() == PcodeOp.CAST || address.getOpcode() == PcodeOp.COPY)) {
                        address = address.getInput(0).getDef();
                    }
                    if (address != null && address.getOpcode() == PcodeOp.PTRSUB
                            && HighFunctionDBUtil.getSpacebaseReferenceAddress(currentProgram.getAddressFactory(), address) != null
                            && currentProgram.getLanguage().getUserDefinedOpName(0) != null
                            && !hasPatchedIdt()) return true;
                }
                default -> { }
            }
        }
        return false;
    }

    /// Whether the language reads SIDT as the patched one does.
    private boolean hasPatchedIdt() {
        for (int index = 0; index < currentProgram.getLanguage().getNumberOfUserDefinedOpNames(); index++) {
            if ("InterruptDescriptorTableBase".equals(currentProgram.getLanguage().getUserDefinedOpName(index))) return true;
        }
        return false;
    }

    /// The function type a call goes through: the callee's signature, or the
    /// field of a typed table or interface it loads its target from.
    private ghidra.program.model.listing.FunctionSignature calledSignature(PcodeOp call) {
        if (call.getOpcode() == PcodeOp.CALL) {
            Function callee = getFunctionAt(call.getInput(0).getAddress());
            return callee == null ? null : callee.getSignature();
        }
        Varnode target = call.getInput(0);
        for (int depth = 0; target != null && depth < 4; depth++) {
            HighVariable held = target.getHigh();
            DataType type = held == null ? null : held.getDataType();
            while (type instanceof TypeDef def) type = def.getBaseDataType();
            if (type instanceof Pointer pointer) {
                DataType at = pointer.getDataType();
                while (at instanceof TypeDef def) at = def.getBaseDataType();
                if (at instanceof FunctionDefinition definition && !"code".equals(definition.getName())) return definition;
            }
            PcodeOp def = target.getDef();
            if (def == null) return null;
            int code = def.getOpcode();
            if (code == PcodeOp.COPY || code == PcodeOp.CAST) { target = def.getInput(0); continue; }
            if (code != PcodeOp.LOAD) return null;
            PcodeOp field = def.getInput(1).getDef();
            if (field == null || (field.getOpcode() != PcodeOp.PTRSUB && field.getOpcode() != PcodeOp.INT_ADD)) return null;
            Varnode tableVarnode = field.getInput(0);
            Varnode offset = field.getInput(1);
            if (!offset.isConstant() || tableVarnode.getHigh() == null) return null;
            DataType tableType = tableVarnode.getHigh().getDataType();
            if (!(tableType instanceof Pointer tablePointer)) return null;
            DataType table = tablePointer.getDataType();
            while (table instanceof TypeDef def2) table = def2.getBaseDataType();
            if (!(table instanceof Structure structure)) return null;
            DataTypeComponent component = structure.getComponentAt((int) offset.getOffset());
            if (component == null) return null;
            DataType slot = component.getDataType();
            while (slot instanceof TypeDef def3) slot = def3.getBaseDataType();
            if (!(slot instanceof Pointer slotPointer)) return null;
            DataType function = slotPointer.getDataType();
            while (function instanceof TypeDef def4) function = def4.getBaseDataType();
            return function instanceof FunctionDefinition definition ? definition : null;
        }
        return null;
    }

    private boolean typeOutArguments(HighFunction high) {
        boolean changed = false;
        Iterator<PcodeOpAST> ops = high.getPcodeOps();
        while (ops.hasNext()) {
            PcodeOpAST op = ops.next();
            if (op.getOpcode() != PcodeOp.CALL && op.getOpcode() != PcodeOp.CALLIND) continue;
            ghidra.program.model.listing.FunctionSignature signature = calledSignature(op);
            if (signature == null) continue;
            ParameterDefinition[] parameters = signature.getArguments();
            for (int index = 0; index < parameters.length && index + 1 < op.getNumInputs(); index++) {
                DataType declared = parameters[index].getDataType();
                while (declared instanceof TypeDef def) declared = def.getBaseDataType();
                if (!(declared instanceof Pointer outer)) continue;
                DataType wanted = outer.getDataType();
                if (!knownPointer(wanted)) continue;
                Varnode argument = op.getInput(index + 1);
                Address global = constantAddress(argument);
                if (global != null) {
                    Data held = currentProgram.getListing().getDataAt(global);
                    Symbol named = currentProgram.getSymbolTable().getPrimarySymbol(global);
                    if (held != null && held.isDefined()
                            && !untyped(held.getDataType(), named == null ? null : named.getSource())) continue;
                    String name = TRACKED.get(key(wanted));
                    if (name != null ? typeGlobal(global, wanted, name, "written through the "
                            + parameters[index].getName() + " argument of " + signature.getName())
                        : putData(global, wanted)) {
                        typedGlobals++;
                        changed = true;
                    }
                    continue;
                }
                PcodeOp reference = argument.getDef();
                while (reference != null && (reference.getOpcode() == PcodeOp.CAST || reference.getOpcode() == PcodeOp.COPY)) {
                    reference = reference.getInput(0).getDef();
                }
                if (reference == null || reference.getOpcode() != PcodeOp.PTRSUB) continue;
                Address stack = HighFunctionDBUtil.getSpacebaseReferenceAddress(
                    currentProgram.getAddressFactory(), reference);
                if (stack == null || !stack.isStackAddress()) continue;
                HighSymbol local = high.getLocalSymbolMap().findLocal(stack, null);
                if (local == null || !untyped(local.getDataType())
                        || local.getDataType() != null && local.getDataType().getLength() != wanted.getLength()) continue;
                if (typeLocal(local, wanted)) changed = true;
            }
        }
        return changed;
    }

    /// A variable a value of a known table or interface type is copied into.
    private boolean typeCopies(HighFunction high) {
        boolean changed = false;
        Iterator<PcodeOpAST> ops = high.getPcodeOps();
        while (ops.hasNext()) {
            PcodeOpAST op = ops.next();
            if (op.getOpcode() != PcodeOp.COPY && op.getOpcode() != PcodeOp.CAST
                    && op.getOpcode() != PcodeOp.LOAD) continue;
            Varnode out = op.getOutput();
            if (out == null || out.getHigh() == null || out.getHigh().getSymbol() == null) continue;
            DataType value = copiedType(op);
            if (!knownPointer(value)) continue;
            // Every value the variable holds must be one of that type: a
            // register a review named for a status, a counter or a length
            // also holds the table pointer for a few instructions.
            DataType wanted = value;
            if (!everyValue(out.getHigh(), at -> {
                    PcodeOp def = at.getDef();
                    if (def == null) return false;
                    if (def.getOpcode() != PcodeOp.COPY && def.getOpcode() != PcodeOp.CAST
                            && def.getOpcode() != PcodeOp.LOAD) return false;
                    DataType held = copiedType(def);
                    return held != null && held.isEquivalent(wanted);
                })) continue;
            if (typeVariable(high, out.getHigh(), value)) changed = true;
        }
        return changed;
    }

    /// Whether every value written into the variable passes `test`. The
    /// joins of branches and the decompiler's indirect effects carry the
    /// values of other writes, so they are passed over.
    private static boolean everyValue(HighVariable variable, java.util.function.Predicate<Varnode> test) {
        if (variable == null) return false;
        boolean any = false;
        for (Varnode instance : variable.getInstances()) {
            PcodeOp def = instance.getDef();
            if (def == null) {
                // Read before any write here: a parameter's or a register's
                // value from the caller — another value.
                if (instance.isInput()) return false;
                continue;
            }
            if (def.getOpcode() == PcodeOp.MULTIEQUAL || def.getOpcode() == PcodeOp.INDIRECT) continue;
            if (!test.test(instance)) return false;
            any = true;
        }
        return any;
    }

    /// The type of the value a COPY, CAST or LOAD writes: the source's, or
    /// for `x = *IdtBase[-1]` the pointer's target.
    private static DataType copiedType(PcodeOp op) {
        {
            DataType value;
            if (op.getOpcode() == PcodeOp.LOAD) {
                // `x = *IdtBase[-1]`: the loaded type is the pointer's target.
                HighVariable from = op.getInput(1).getHigh();
                DataType pointerType = from == null ? null : from.getDataType();
                value = pointerType instanceof Pointer pointer ? pointer.getDataType() : null;
                if (value == null) {
                    PcodeOp address = op.getInput(1).getDef();
                    if (address != null && (address.getOpcode() == PcodeOp.PTRADD || address.getOpcode() == PcodeOp.INT_ADD)
                            && address.getInput(0).getHigh() != null
                            && address.getInput(0).getHigh().getDataType() instanceof Pointer pointer) {
                        value = pointer.getDataType();
                    }
                }
            } else {
                HighVariable from = op.getInput(0).getHigh();
                value = from == null ? null : from.getDataType();
            }
            return value;
        }
    }

    private void typeReturn(HighFunction high) {
        Function function = high.getFunction();
        if (!untyped(function.getReturnType(), function.getSignatureSource())
                || function.getReturnType() instanceof VoidDataType) return;
        DataType found = null;
        Iterator<PcodeOpAST> ops = high.getPcodeOps();
        while (ops.hasNext()) {
            PcodeOpAST op = ops.next();
            if (op.getOpcode() != PcodeOp.RETURN) continue;
            if (op.getNumInputs() < 2 || op.getInput(1).getHigh() == null) return;
            DataType value = op.getInput(1).getHigh().getDataType();
            if (!knownPointer(value)) {
                PcodeOp def = op.getInput(1).getDef();
                if (def != null && def.getOpcode() == PcodeOp.LOAD && def.getInput(1).getHigh() != null
                        && def.getInput(1).getHigh().getDataType() instanceof Pointer pointer) {
                    value = pointer.getDataType();
                }
            }
            if (!knownPointer(value)) return;
            if (found != null && !found.isEquivalent(value)) return;
            found = value;
        }
        if (found == null || found.getLength() != function.getReturnType().getLength()
                && !Undefined.isUndefined(function.getReturnType())) return;
        try {
            SourceType source = function.getSignatureSource() == SourceType.DEFAULT
                ? SourceType.ANALYSIS : function.getSignatureSource();
            function.setReturnType(found, source);
            typedReturns++;
        } catch (Exception refused) {
            // The return storage cannot hold it.
        }
    }

    // MARK: - DEBUG strings

    /// DEBUG ((DEBUG_INFO, "%a: …", __FUNCTION__)) puts the function's own
    /// name in its data. A function whose calls pass a "%a" format and one
    /// identifier-like string is named by it — unless another function claims
    /// the same identifier, which is then not evidence of either.
    private void nameFromDebugStrings() throws Exception {
        Map<String, List<Function>> claims = new HashMap<>();
        for (Function function : currentProgram.getFunctionManager().getFunctions(true)) {
            if (monitor.isCancelled()) break;
            if (function.getSymbol().getSource() != SourceType.DEFAULT) continue;
            HighFunction high = decompile(function);
            if (high == null) continue;
            Set<String> found = new HashSet<>();
            Iterator<PcodeOpAST> ops = high.getPcodeOps();
            while (ops.hasNext()) {
                PcodeOpAST op = ops.next();
                if (op.getOpcode() != PcodeOp.CALL && op.getOpcode() != PcodeOp.CALLIND) continue;
                boolean format = false;
                List<String> identifiers = new ArrayList<>();
                for (int slot = 1; slot < op.getNumInputs(); slot++) {
                    String text = ascii(constantAddress(op.getInput(slot)));
                    if (text == null) continue;
                    if (text.contains("%a")) format = true;
                    else if (IDENTIFIER.matcher(text).matches()) identifiers.add(text);
                }
                if (format && identifiers.size() == 1) found.add(identifiers.get(0));
            }
            if (found.size() == 1) {
                claims.computeIfAbsent(found.iterator().next(), key -> new ArrayList<>()).add(function);
            }
        }
        for (Map.Entry<String, List<Function>> claim : claims.entrySet()) {
            if (claim.getValue().size() != 1) continue;
            name(claim.getValue().get(0), claim.getKey(),
                "its DEBUG message passes \"" + claim.getKey() + "\" for a %a — EDK2's __FUNCTION__");
        }
    }

    /// The NUL-terminated ASCII at an address, or null when it is not text.
    private String ascii(Address address) {
        if (address == null) return null;
        StringBuilder text = new StringBuilder();
        try {
            for (int i = 0; i < 256; i++) {
                int c = currentProgram.getMemory().getByte(address.add(i)) & 0xFF;
                if (c == 0) return text.length() > 0 ? text.toString() : null;
                if (c < 0x20 && c != '\n' && c != '\r' && c != '\t' || c >= 0x7F) return null;
                text.append((char) c);
            }
        } catch (Exception error) {
            return null;
        }
        return null;
    }
}
