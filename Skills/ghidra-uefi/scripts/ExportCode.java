// Export one analyzed program as the rich, read-later code artifact.
//
//   analyzeHeadless ... -postScript ExportCode.java out.json
//
// The artifact is what the Code panel and an agent read after Ghidra is gone:
// every function with its decompiled C, every instruction with its bytes and
// references, the program's blocks, its strings, and the writes to the POST
// port. The JSON is intentionally explicit rather than compact; a module of a
// few kilobytes stays small, and a reader can see what was written.
// @category ByteRipper

import java.io.File;
import java.io.Writer;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

import ghidra.app.decompiler.ClangFuncNameToken;
import ghidra.app.decompiler.ClangLine;
import ghidra.app.decompiler.ClangToken;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.decompiler.PrettyPrinter;
import ghidra.app.script.GhidraScript;
import ghidra.framework.Application;
import ghidra.program.model.address.Address;
import ghidra.program.model.address.AddressSet;
import ghidra.program.model.data.DataType;
import ghidra.program.model.listing.Data;
import ghidra.program.model.listing.DataIterator;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionIterator;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.InstructionIterator;
import ghidra.program.model.listing.Listing;
import ghidra.program.model.mem.MemoryBlock;
import ghidra.program.model.pcode.HighFunction;
import ghidra.program.model.pcode.HighSymbol;
import ghidra.program.model.pcode.PcodeOp;
import ghidra.program.model.pcode.Varnode;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.SourceType;
import ghidra.program.model.symbol.Symbol;
import ghidra.program.model.symbol.SymbolIterator;
import ghidra.program.model.symbol.SymbolType;
import ghidra.program.model.util.StringPropertyMap;
import ghidra.program.model.pcode.HighParam;
import ghidra.program.model.pcode.PcodeOpAST;
import ghidra.program.model.listing.Program;

public class ExportCode extends GhidraScript {

    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length < 1) {
            println("usage: ExportCode.java <out.json>");
            return;
        }
        File out = new File(args[0]);

        Listing listing = currentProgram.getListing();
        StringBuilder json = new StringBuilder(1 << 22);
        json.append("{\n");
        json.append("  \"script_version\": 5,\n");
        json.append("  \"ghidra\": ").append(quote(Application.getApplicationVersion())).append(",\n");
        json.append("  \"program\": {\n");
        json.append("    \"name\": ").append(quote(currentProgram.getName())).append(",\n");
        json.append("    \"language\": ").append(quote(currentProgram.getLanguageID().toString())).append(",\n");
        json.append("    \"image_base\": ").append(quote(hex(currentProgram.getImageBase()))).append(",\n");
        json.append("    \"sha256\": ").append(quote(currentProgram.getExecutableSHA256())).append("\n");
        json.append("  },\n");

        // Blocks: the address ranges the program has, and whether they are code.
        json.append("  \"blocks\": [");
        MemoryBlock[] blocks = currentProgram.getMemory().getBlocks();
        for (int i = 0; i < blocks.length; i++) {
            MemoryBlock block = blocks[i];
            if (i > 0) json.append(", ");
            json.append("{\"name\": ").append(quote(block.getName()))
                .append(", \"start\": ").append(quote(hex(block.getStart())))
                .append(", \"end\": ").append(quote(hex(block.getEnd())))
                .append(", \"executable\": ").append(block.isExecute())
                .append(", \"initialized\": ").append(block.isInitialized())
                .append("}");
        }
        json.append("],\n");

        // Strings worth naming: every defined string, whatever Ghidra's type
        // for it — `string`, `TerminatedCString`, `unicode`,
        // `TerminatedUnicode` — and then the UTF-16 runs Ghidra left as bytes.
        // UEFI names its variables and its menus in UTF-16 (`L"BootOrder"`);
        // a list without them misses what a repair is usually looking for.
        List<long[]> stringOrder = new ArrayList<>();
        List<String> stringEntries = new ArrayList<>();
        AddressSet definedStrings = new AddressSet();
        DataIterator data = listing.getDefinedData(true);
        while (data.hasNext() && !monitor.isCancelled()) {
            Data item = data.next();
            if (!item.hasStringValue()) continue;
            DataType type = item.getDataType();
            Object value;
            try {
                value = item.getValue();
            } catch (Exception error) {
                continue;
            }
            if (value == null) continue;
            definedStrings.add(item.getMinAddress(), item.getMaxAddress());
            stringOrder.add(new long[] { item.getAddress().getOffset(), stringEntries.size() });
            stringEntries.add("{\"address\": " + quote(hex(item.getAddress()))
                + ", \"type\": " + quote(type == null ? "string" : type.getName())
                + ", \"value\": " + quote(value.toString()) + "}");
        }
        for (MemoryBlock block : blocks) {
            if (monitor.isCancelled()) break;
            if (!block.isInitialized() || block.getSize() > (64L << 20)) continue;
            byte[] bytes = new byte[(int) block.getSize()];
            try {
                block.getBytes(block.getStart(), bytes);
            } catch (Exception error) {
                continue;
            }
            int index = 0;
            while (index + 1 < bytes.length) {
                int length = 0;
                while (index + 2 * length + 1 < bytes.length
                        && bytes[index + 2 * length + 1] == 0
                        && isText(bytes[index + 2 * length])) {
                    length++;
                }
                boolean terminated = index + 2 * length + 1 < bytes.length
                    && bytes[index + 2 * length] == 0 && bytes[index + 2 * length + 1] == 0;
                if (length >= 4 && terminated) {
                    Address start = block.getStart().add(index);
                    if (!definedStrings.contains(start)
                            && listing.getInstructionContaining(start) == null) {
                        StringBuilder text = new StringBuilder(length);
                        for (int at = 0; at < length; at++) text.append((char) bytes[index + 2 * at]);
                        stringOrder.add(new long[] { start.getOffset(), stringEntries.size() });
                        stringEntries.add("{\"address\": " + quote(hex(start))
                            + ", \"type\": \"unicode\", \"value\": " + quote(text.toString())
                            + ", \"source\": \"scan\"}");
                    }
                    index += 2 * (length + 1);
                } else {
                    index += 2;
                }
            }
        }
        stringOrder.sort((left, right) -> Long.compare(left[0], right[0]));
        List<String> strings = new ArrayList<>();
        for (long[] entry : stringOrder) strings.add(stringEntries.get((int) entry[1]));
        json.append("  \"strings\": [").append(String.join(", ", strings)).append("],\n");

        StringPropertyMap reasons =
            currentProgram.getUsrPropertyManager().getStringPropertyMap("ByteRipper.nameReason");
        // Named data: the GUIDs, service tables and interfaces the UEFI pass
        // named, and whatever the image's own symbols named.
        List<String> symbols = new ArrayList<>();
        SymbolIterator named = currentProgram.getSymbolTable().getPrimarySymbolIterator(true);
        while (named.hasNext() && !monitor.isCancelled()) {
            Symbol symbol = named.next();
            if (symbol.getSymbolType() != SymbolType.LABEL || symbol.getSource() == SourceType.DEFAULT
                    || !symbol.getAddress().isMemoryAddress()) continue;
            Data item = listing.getDataAt(symbol.getAddress());
            String why = reasons == null ? null : reasons.getString(symbol.getAddress());
            symbols.add("{\"address\": " + quote(hex(symbol.getAddress()))
                + ", \"name\": " + quote(symbol.getName())
                + ", \"type\": " + quote(item == null ? null : item.getDataType().getDisplayName())
                + ", \"source\": " + quote(symbol.getSource().name())
                + (why == null ? "" : ", \"reason\": " + quote(why)) + "}");
        }
        json.append("  \"symbols\": [").append(String.join(", ", symbols)).append("],\n");

        // Functions, in address order, with their instructions and decompiled C.
        DecompInterface decompiler = new DecompInterface();
        decompiler.toggleCCode(true);
        decompiler.toggleSyntaxTree(true);
        decompiler.openProgram(currentProgram);

        List<Function> functions = new ArrayList<>();
        FunctionIterator iterator = currentProgram.getFunctionManager().getFunctions(true);
        while (iterator.hasNext() && !monitor.isCancelled()) functions.add(iterator.next());

        PortWrites ports = new PortWrites(currentProgram);
        List<String> statusCodeCalls = new ArrayList<>();
        // `[reg + 0x58]` is ReportStatusCode in the 32-bit PEI services
        // table. In a 64-bit image the same slot is Boot Services' SetTimer or
        // Runtime Services' SetVariable, so no candidate is named there.
        boolean thirtyTwoBit = currentProgram.getLanguage().getLanguageDescription().getSize() == 32;
        json.append("  \"functions\": [\n");
        for (int index = 0; index < functions.size(); index++) {
            Function function = functions.get(index);
            if (monitor.isCancelled()) break;
            json.append("    {\n");
            json.append("      \"entry\": ").append(quote(hex(function.getEntryPoint()))).append(",\n");
            json.append("      \"name\": ").append(quote(function.getName())).append(",\n");
            json.append("      \"size\": ").append(function.getBody().getNumAddresses()).append(",\n");
            json.append("      \"external\": ").append(function.isExternal()).append(",\n");
            json.append("      \"thunk\": ").append(function.isThunk()).append(",\n");
            json.append("      \"signature\": ").append(quote(function.getPrototypeString(false, false))).append(",\n");

            // Ghidra answers with sets; sorted by entry, the same program
            // always exports the same bytes, which is what lets a publish of
            // an unchanged program be recognised as one.
            List<String> callers = entries(function.getCallingFunctions(monitor));
            List<String> callees = entries(function.getCalledFunctions(monitor));
            json.append("      \"callers\": [").append(String.join(", ", callers)).append("],\n");
            json.append("      \"callees\": [").append(String.join(", ", callees)).append("],\n");

            // Where the name came from: Ghidra's FUN_ placeholder (DEFAULT),
            // the UEFI pass (ANALYSIS, with its reason), the image's own
            // symbols (IMPORTED) or a user.
            json.append("      \"name_source\": ")
                .append(quote(function.getSymbol().getSource().name())).append(",\n");
            String reason = reasons == null ? null : reasons.getString(function.getEntryPoint());
            if (reason != null) {
                json.append("      \"name_reason\": ").append(quote(reason)).append(",\n");
            }

            if (!function.isExternal() && !function.isThunk()) {
                DecompileResults results = decompiler.decompileFunction(function, 120, monitor);
                if (results != null && results.decompileCompleted()
                        && results.getCCodeMarkup() != null) {
                    appendC(json, function, results);
                }
                if (results != null && results.decompileCompleted() && results.getHighFunction() != null) {
                    ports.collect(function, results.getHighFunction());
                }
            }

            List<String> instructions = new ArrayList<>();
            List<String> recent = new ArrayList<>();
            InstructionIterator code = listing.getInstructions(function.getBody(), true);
            while (code.hasNext() && !monitor.isCancelled()) {
                Instruction instruction = code.next();
                String bytes = "";
                try {
                    bytes = hexBytes(instruction.getBytes());
                } catch (Exception ignored) {
                    // A partly mapped instruction still has text worth keeping.
                }
                List<String> references = new ArrayList<>();
                Reference[] refs = instruction.getReferencesFrom();
                for (Reference reference : refs) {
                    if (reference.getReferenceType().isFallthrough()) continue;
                    references.add("{\"to\": " + quote(hex(reference.getToAddress()))
                        + ", \"type\": " + quote(reference.getReferenceType().toString()) + "}");
                }
                String text = instruction.toString();
                // A call through a table entry at +0x58 is the PEI
                // ReportStatusCode call in a 32-bit PEI services table; the
                // pushes just before it carry Type and Value. A candidate,
                // because another table could use the same displacement.
                if (thirtyTwoBit && instruction.getFlowType().isCall() && text.matches(".*\\[\\s*\\w+\\s*\\+\\s*0x58\\s*\\].*")) {
                    List<String> context = new ArrayList<>(recent);
                    statusCodeCalls.add("{\"address\": " + quote(hex(instruction.getAddress()))
                        + ", \"function\": " + quote(hex(function.getEntryPoint()))
                        + ", \"text\": " + quote(text)
                        + ", \"context\": ["
                        + String.join(", ", context.stream().map(ExportCode::quote).toList())
                        + "]}");
                }
                instructions.add("{\"address\": " + quote(hex(instruction.getAddress()))
                    + ", \"bytes\": " + quote(bytes)
                    + ", \"mnemonic\": " + quote(instruction.getMnemonicString())
                    + ", \"text\": " + quote(text)
                    + ", \"flow\": " + quote(instruction.getFlowType().toString())
                    + ", \"references\": [" + String.join(", ", references) + "]}");

                recent.add(text);
                if (recent.size() > 8) recent.remove(0);
            }
            json.append("      \"instructions\": [\n        ")
                .append(String.join(",\n        ", instructions)).append("\n      ]\n");
            json.append("    }");
            if (index + 1 < functions.size()) json.append(",");
            json.append("\n");
        }
        json.append("  ],\n");
        // The POST codes: what the code writes to port 0x80, at the place it
        // supplies the value — through IoWrite8, a PostCode() or a halt
        // routine — and the writes to every other port the same way.
        List<String> postCodes = new ArrayList<>();
        List<String> portWrites = new ArrayList<>();
        for (PortWrites.Write write : ports.resolve()) {
            Instruction at = listing.getInstructionAt(write.site);
            Function in = currentProgram.getFunctionManager().getFunctionContaining(write.site);
            List<String> via = new ArrayList<>();
            for (Address wrapper : write.via) {
                Function called = currentProgram.getFunctionManager().getFunctionAt(wrapper);
                via.add("{\"function\": " + quote(hex(wrapper))
                    + ", \"name\": " + quote(called == null ? null : called.getName()) + "}");
            }
            String entry = "{\"address\": " + quote(hex(write.site))
                + ", \"function\": " + quote(in == null ? null : hex(in.getEntryPoint()))
                + ", \"port\": " + quote(write.port == null ? null : hex(write.port))
                + ", \"value\": " + quote(write.value == null ? null : hex(write.value))
                + ", \"width\": " + write.width
                + (write.unresolved == null ? "" : ", \"unresolved\": " + quote(write.unresolved))
                + ", \"via\": [" + String.join(", ", via) + "]"
                + ", \"text\": " + quote(at == null ? null : at.toString()) + "}";
            if (write.port == null || write.port == PortWrites.POST_PORT) postCodes.add(entry);
            else portWrites.add(entry);
        }
        json.append("  \"post_codes\": [").append(String.join(", ", postCodes)).append("],\n");
        json.append("  \"port_writes\": [").append(String.join(", ", portWrites)).append("],\n");
        json.append("  \"status_code_calls\": [")
            .append(String.join(", ", statusCodeCalls)).append("]\n");
        json.append("}\n");

        try (Writer writer = Files.newBufferedWriter(out.toPath(), StandardCharsets.UTF_8)) {
            writer.write(json.toString());
        }
        decompiler.dispose();
        println("wrote " + functions.size() + " functions to " + out);
    }

    // The decompiled C, written from the decompiler's tokens so that every
    // token's place in the text is known, and the spans a reader colours and
    // follows: a called function with its entry, a global with its address,
    // a type, a parameter, a local, a constant, a keyword, a comment. Offsets
    // are UTF-16 code units into `c`, the units a Swift or Java string counts.
    private void appendC(StringBuilder json, Function function, DecompileResults results) {
        PrettyPrinter printer = new PrettyPrinter(function, results.getCCodeMarkup(), null);
        HighFunction high = results.getHighFunction();
        StringBuilder text = new StringBuilder();
        List<String> spans = new ArrayList<>();
        // Where each call in the text is made: the call's own address, so a
        // place in the listing — a POST code's call, a status-code call —
        // is found in the C too.
        List<String> sites = new ArrayList<>();
        for (ClangLine line : printer.getLines()) {
            text.append(line.getIndentString());
            for (ClangToken token : line.getAllTokens()) {
                String piece = token.getText();
                int start = text.length();
                text.append(piece);
                if (piece.isEmpty() || piece.isBlank()) continue;
                PcodeOp callOp = token.getPcodeOp();
                if (callOp != null && (callOp.getOpcode() == PcodeOp.CALL || callOp.getOpcode() == PcodeOp.CALLIND
                        || callOp.getOpcode() == PcodeOp.CALLOTHER)
                        && token.getSyntaxType() == ClangToken.FUNCTION_COLOR) {
                    sites.add("[" + start + ", " + piece.length() + ", "
                        + quote(hex(callOp.getSeqnum().getTarget())) + "]");
                }
                String kind = null;
                String target = null;
                switch (token.getSyntaxType()) {
                    case ClangToken.KEYWORD_COLOR: kind = "keyword"; break;
                    case ClangToken.COMMENT_COLOR: kind = "comment"; break;
                    case ClangToken.TYPE_COLOR: kind = "type"; break;
                    case ClangToken.CONST_COLOR: kind = "constant"; break;
                    case ClangToken.PARAMETER_COLOR: kind = "parameter"; break;
                    case ClangToken.VARIABLE_COLOR: kind = "local"; break;
                    case ClangToken.FUNCTION_COLOR:
                        kind = "function";
                        target = calledEntry(token);
                        break;
                    case ClangToken.GLOBAL_COLOR:
                        kind = "global";
                        target = globalAddress(token, high);
                        break;
                    default: break;
                }
                if (kind == null) continue;
                spans.add("[" + start + ", " + piece.length() + ", " + quote(kind)
                    + (target == null ? "" : ", " + quote(target)) + "]");
            }
            text.append('\n');
        }
        json.append("      \"c\": ").append(quote(text.toString())).append(",\n");
        json.append("      \"c_spans\": [").append(String.join(", ", spans)).append("],\n");
        json.append("      \"c_sites\": [").append(String.join(", ", sites)).append("],\n");
    }

    // The entry a function-name token calls, or names: the CALL's target, or
    // the function of that name.
    private String calledEntry(ClangToken token) {
        PcodeOp op = token.getPcodeOp();
        if (op != null && op.getOpcode() == PcodeOp.CALL) {
            return hex(op.getInput(0).getAddress());
        }
        if (token instanceof ClangFuncNameToken) {
            List<Function> functions = getGlobalFunctions(token.getText());
            if (functions.size() == 1) return hex(functions.get(0).getEntryPoint());
        }
        return null;
    }

    // The address of a global a token names.
    private String globalAddress(ClangToken token, HighFunction high) {
        try {
            HighSymbol symbol = token.getHighSymbol(high);
            if (symbol != null && symbol.isGlobal() && symbol.getStorage() != null) {
                Address address = symbol.getStorage().getMinAddress();
                if (address != null && address.isMemoryAddress()) return hex(address);
            }
        } catch (Exception ignored) {
            // A token whose symbol cannot be read has no target.
        }
        Varnode varnode = token.getVarnode();
        if (varnode != null && varnode.isAddress() && varnode.getAddress().isMemoryAddress()) {
            return hex(varnode.getAddress());
        }
        return null;
    }

    private static List<String> entries(java.util.Set<Function> functions) {
        List<Address> addresses = new ArrayList<>();
        for (Function function : functions) addresses.add(function.getEntryPoint());
        java.util.Collections.sort(addresses);
        List<String> quoted = new ArrayList<>();
        for (Address address : addresses) quoted.add(quote(hex(address)));
        return quoted;
    }

    private static String hex(Address address) {
        return "0x" + Long.toHexString(address.getOffset()).toUpperCase();
    }

    private static String hex(long value) {
        return String.format("0x%X", value);
    }

    // A UTF-16 code unit's low byte that reads as text: printable ASCII, a
    // tab or a line break.
    private static boolean isText(byte value) {
        int c = value & 0xFF;
        return (c >= 0x20 && c < 0x7F) || c == '\t' || c == '\n' || c == '\r';
    }

    private static String hexBytes(byte[] bytes) {
        StringBuilder builder = new StringBuilder();
        for (byte value : bytes) {
            if (builder.length() > 0) builder.append(' ');
            builder.append(String.format("%02X", value & 0xFF));
        }
        return builder.toString();
    }

    private static String quote(String value) {
        if (value == null) return "null";
        StringBuilder builder = new StringBuilder("\"");
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            switch (c) {
                case '"': builder.append("\\\""); break;
                case '\\': builder.append("\\\\"); break;
                case '\n': builder.append("\\n"); break;
                case '\r': builder.append("\\r"); break;
                case '\t': builder.append("\\t"); break;
                case '\b': builder.append("\\b"); break;
                case '\f': builder.append("\\f"); break;
                default:
                    if (c < 0x20) builder.append(String.format("\\u%04x", (int) c));
                    else builder.append(c);
            }
        }
        return builder.append("\"").toString();
    }

    // The writes to I/O ports, followed back to the place that supplies the
    // value. A POST code is seldom `OUT 0x80, imm` where it is sent: the
    // constant is an argument of IoWrite8, of a PostCode(), of a vendor's
    // halt routine that writes it and spins, and the OUT itself reads two
    // parameters. So each OUT's port and value are read from the
    // decompiler's p-code as constants or as parameters of its function;
    // where one is a parameter, the function is a wrapper, and each call of
    // it is read the same way with the argument in that place — up to four
    // wrappers deep. A value passed by pointer (`IoWrite(Width, Port,
    // &Value)`) is the constant stored to that local before the call. What
    // stays a parameter or is computed is kept, as unresolved, so a list of
    // the module's codes says where it could not tell.
    static final class PortWrites {
        static final long POST_PORT = 0x80;
        static final int DEPTH = 4;
        static final int MOST = 16;

        // What a varnode holds: a few constants, a parameter, what a
        // parameter points at, or something computed.
        static final class Value {
            final java.util.TreeSet<Long> constants = new java.util.TreeSet<>();
            int parameter = -1;
            int pointee = -1;
            boolean computed;

            boolean open() { return parameter >= 0 || pointee >= 0; }

            static Value constant(long value) { Value v = new Value(); v.constants.add(value); return v; }
            static Value computed() { Value v = new Value(); v.computed = true; return v; }

            void merge(Value other) {
                constants.addAll(other.constants);
                if (other.parameter >= 0) parameter = parameter < 0 || parameter == other.parameter ? other.parameter : parameter;
                if (other.pointee >= 0) pointee = pointee < 0 || pointee == other.pointee ? other.pointee : pointee;
                computed |= other.computed;
                if (constants.size() > MOST) { constants.clear(); computed = true; }
            }

            Value masked(int size) {
                Value v = new Value();
                long mask = size >= 8 ? -1L : (1L << (8 * size)) - 1;
                for (long c : constants) v.constants.add(c & mask);
                v.parameter = parameter; v.pointee = pointee; v.computed = computed;
                return v;
            }
        }

        // A call of a function with a known entry: each argument, and what
        // it points at when it is the address of a local.
        static final class Call {
            Address site;
            Address target;
            List<Value> arguments = new ArrayList<>();
            List<Value> pointees = new ArrayList<>();
        }

        static final class Sink {
            Address site;
            Address function;
            Value port;
            Value value;
            int width;
            List<Address> via = new ArrayList<>();
        }

        static final class Write {
            Address site;
            Long port;
            Long value;
            int width;
            String unresolved;
            List<Address> via;
        }

        private final Program program;
        private final List<Sink> sinks = new ArrayList<>();
        private final Map<Address, List<Call>> callsTo = new java.util.HashMap<>();

        PortWrites(Program program) { this.program = program; }

        void collect(Function function, HighFunction high) {
            java.util.Iterator<PcodeOpAST> ops = high.getPcodeOps();
            while (ops.hasNext()) {
                PcodeOpAST op = ops.next();
                if (op.getOpcode() == PcodeOp.CALLOTHER && op.getNumInputs() >= 3
                        && "out".equals(program.getLanguage().getUserDefinedOpName((int) op.getInput(0).getOffset()))) {
                    Sink sink = new Sink();
                    sink.site = op.getSeqnum().getTarget();
                    sink.function = function.getEntryPoint();
                    sink.port = value(op.getInput(1), 0);
                    sink.value = value(op.getInput(2), 0);
                    sink.width = op.getInput(2).getSize();
                    sinks.add(sink);
                } else if (op.getOpcode() == PcodeOp.CALL && op.getInput(0).isAddress()) {
                    Call call = new Call();
                    call.site = op.getSeqnum().getTarget();
                    call.target = op.getInput(0).getAddress();
                    for (int i = 1; i < op.getNumInputs(); i++) {
                        call.arguments.add(value(op.getInput(i), 0));
                        call.pointees.add(pointee(op.getInput(i), high));
                    }
                    callsTo.computeIfAbsent(call.target, key -> new ArrayList<>()).add(call);
                }
            }
        }

        private static Value value(Varnode varnode, int depth) {
            int size = varnode.getSize();
            if (varnode.isConstant()) return Value.constant(varnode.getOffset()).masked(size);
            if (varnode.getHigh() instanceof HighParam param && varnode.getDef() == null) {
                Value v = new Value(); v.parameter = param.getSlot(); return v;
            }
            PcodeOp def = varnode.getDef();
            if (def == null || depth > 12) return Value.computed();
            switch (def.getOpcode()) {
                case PcodeOp.COPY: case PcodeOp.CAST: case PcodeOp.INT_ZEXT: case PcodeOp.INDIRECT:
                    return value(def.getInput(0), depth + 1).masked(size);
                case PcodeOp.INT_SEXT: {
                    Value inner = value(def.getInput(0), depth + 1);
                    int from = def.getInput(0).getSize();
                    Value v = new Value();
                    for (long c : inner.constants) v.constants.add((c << (64 - 8 * from)) >> (64 - 8 * from));
                    v.parameter = inner.parameter; v.pointee = inner.pointee; v.computed = inner.computed;
                    return v.masked(size);
                }
                case PcodeOp.SUBPIECE: {
                    Value inner = value(def.getInput(0), depth + 1);
                    long shift = def.getInput(1).getOffset() * 8;
                    if (shift != 0 && inner.open()) return Value.computed();
                    Value v = new Value();
                    for (long c : inner.constants) v.constants.add(c >>> shift);
                    v.parameter = inner.parameter; v.pointee = inner.pointee; v.computed = inner.computed;
                    return v.masked(size);
                }
                case PcodeOp.MULTIEQUAL: {
                    Value v = new Value();
                    for (int i = 0; i < def.getNumInputs(); i++) v.merge(value(def.getInput(i), depth + 1));
                    return v.masked(size);
                }
                case PcodeOp.LOAD: {
                    Value pointer = value(def.getInput(1), depth + 1);
                    Value v = new Value();
                    if (pointer.parameter >= 0 && pointer.constants.isEmpty()) v.pointee = pointer.parameter;
                    else v.computed = true;
                    return v;
                }
                case PcodeOp.INT_OR: case PcodeOp.INT_AND: case PcodeOp.INT_XOR: case PcodeOp.INT_ADD:
                case PcodeOp.INT_LEFT: case PcodeOp.INT_RIGHT: {
                    Value left = value(def.getInput(0), depth + 1);
                    Value right = value(def.getInput(1), depth + 1);
                    if (left.open() || right.open() || left.computed || right.computed
                            || left.constants.size() * right.constants.size() > MOST) return Value.computed();
                    Value v = new Value();
                    for (long a : left.constants) for (long b : right.constants) {
                        v.constants.add(switch (def.getOpcode()) {
                            case PcodeOp.INT_OR -> a | b;
                            case PcodeOp.INT_AND -> a & b;
                            case PcodeOp.INT_XOR -> a ^ b;
                            case PcodeOp.INT_ADD -> a + b;
                            case PcodeOp.INT_LEFT -> a << b;
                            default -> a >>> b;
                        });
                    }
                    return v.masked(size);
                }
                default:
                    return Value.computed();
            }
        }

        // What an argument points at when it is the address of a local of
        // the caller (`&local_8`): every constant the function stores there.
        private static Value pointee(Varnode argument, HighFunction high) {
            PcodeOp def = argument.getDef();
            while (def != null && (def.getOpcode() == PcodeOp.COPY || def.getOpcode() == PcodeOp.CAST)) {
                def = def.getInput(0).getDef();
            }
            if (def == null || def.getOpcode() != PcodeOp.PTRSUB || !def.getInput(1).isConstant()) {
                Value passed = value(argument, 0);
                Value v = new Value();
                if (passed.parameter >= 0) v.parameter = passed.parameter;
                else v.computed = true;
                return v;
            }
            int bits = argument.getSize() * 8;
            long offset = (def.getInput(1).getOffset() << (64 - bits)) >> (64 - bits);
            Value v = new Value();
            boolean found = false;
            java.util.Iterator<PcodeOpAST> ops = high.getPcodeOps();
            while (ops.hasNext()) {
                PcodeOpAST op = ops.next();
                Varnode out = op.getOutput();
                if (out == null || !out.getAddress().isStackAddress() || out.getAddress().getOffset() != offset) continue;
                if (op.getOpcode() == PcodeOp.INDIRECT || op.getOpcode() == PcodeOp.MULTIEQUAL) continue;
                found = true;
                v.merge(value(out, 0));
            }
            if (!found) v.computed = true;
            return v;
        }

        // A parameter (or what it points at) of a wrapper, as a call of it
        // passes it.
        private static Value substitute(Value value, Call call) {
            Value v = new Value();
            v.constants.addAll(value.constants);
            v.computed = value.computed;
            if (value.parameter >= 0) {
                if (value.parameter < call.arguments.size()) v.merge(call.arguments.get(value.parameter));
                else v.computed = true;
            }
            if (value.pointee >= 0) {
                if (value.pointee < call.pointees.size()) {
                    Value pointed = call.pointees.get(value.pointee);
                    // The caller passed its own pointer parameter along.
                    if (pointed.parameter >= 0) { Value p = new Value(); p.pointee = pointed.parameter; pointed = p; }
                    v.merge(pointed);
                } else {
                    v.computed = true;
                }
            }
            return v;
        }

        List<Write> resolve() {
            List<Sink> done = new ArrayList<>();
            java.util.ArrayDeque<Sink> queue = new java.util.ArrayDeque<>(sinks);
            while (!queue.isEmpty()) {
                Sink sink = queue.removeFirst();
                List<Call> calls = callsTo.getOrDefault(sink.function, List.of());
                boolean open = sink.port.open() || sink.value.open();
                // A port known not to be POST's is not followed further
                // than the value needs; a wrapper with no known caller, or
                // past the depth, stays as it is.
                if (!open || calls.isEmpty() || sink.via.size() >= DEPTH) { done.add(sink); continue; }
                boolean followed = false;
                for (Call call : calls) {
                    Function caller = program.getFunctionManager().getFunctionContaining(call.site);
                    if (caller == null || sink.via.contains(caller.getEntryPoint()) || caller.getEntryPoint().equals(sink.function)) continue;
                    Sink next = new Sink();
                    next.site = call.site;
                    next.function = caller.getEntryPoint();
                    next.port = substitute(sink.port, call);
                    next.value = substitute(sink.value, call);
                    next.width = sink.width;
                    next.via.add(sink.function);
                    next.via.addAll(sink.via);
                    queue.addLast(next);
                    followed = true;
                }
                if (!followed) done.add(sink);
            }
            List<Write> writes = new ArrayList<>();
            for (Sink sink : done) {
                List<Long> portValues = new ArrayList<>(sink.port.constants);
                if (portValues.isEmpty()) portValues.add(null);
                List<Long> values = new ArrayList<>(sink.value.constants);
                if (values.isEmpty() || sink.value.open() || sink.value.computed) values.add(null);
                for (Long port : portValues) {
                    for (Long value : values) {
                        Write write = new Write();
                        write.site = sink.site;
                        write.port = port;
                        write.value = value;
                        write.width = sink.width;
                        write.via = sink.via;
                        if (port == null) write.unresolved = sink.port.open() ? "port-parameter" : "port-computed";
                        else if (value == null) write.unresolved = sink.value.open() ? "value-parameter" : "value-computed";
                        writes.add(write);
                    }
                }
            }
            // One OUT reached through a width switch (IoWrite of 1, 2 or 4
            // bytes) is one write: the widest is kept.
            Map<String, Write> unique = new java.util.LinkedHashMap<>();
            for (Write write : writes) {
                String key = write.site + "/" + write.port + "/" + write.value + "/" + write.via;
                Write kept = unique.get(key);
                if (kept == null || kept.width < write.width) unique.put(key, write);
            }
            writes = new ArrayList<>(unique.values());
            writes.sort((a, b) -> {
                int bySite = a.site.compareTo(b.site);
                if (bySite != 0) return bySite;
                int byPort = Long.compare(a.port == null ? -1 : a.port, b.port == null ? -1 : b.port);
                if (byPort != 0) return byPort;
                return Long.compare(a.value == null ? -1 : a.value, b.value == null ? -1 : b.value);
            });
            return writes;
        }
    }
}
