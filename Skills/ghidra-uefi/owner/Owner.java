// The Ghidra owner of one module (Design/GHIDRA_SHARED_PLAN.md §6): a
// long-lived headless Ghidra that holds one program of a kept project and
// serves the bridge (§7) on a loopback port.
//
// The reads; the writes of a review (phase 2a) — function and variable
// names with who made them and why, signatures, comments, data, types — each
// in a transaction of its own and only under the write lease; and publish,
// which saves the program if it changed, runs ExportCode on it in this
// process, harvests the review document (Harvest.java) and returns the
// artifact. The client stores both. Nothing here writes to the store, and
// nothing here runs a script a client names.
//
// How it is built and run is `scripts/ghidra_owner.py`'s business: javac
// against every jar of the Ghidra install, then
//
//   java -cp <ghidra jars>:owner.jar Owner --project-dir D --project-name N
//        --program P --module SHA --project-id UUID [--types ARCHIVE.gdt]
//        [--review-types DIR] [--port 0] [--idle SECONDS]
//
// --review-types names the folder of the archives of types reviews define
// (`review-types-Ia32.gdt`, `review-types-X64.gdt`, §6.5): the owner reads a
// copy taken when it starts, and merges its own review's types in at publish.
//
// It prints `OWNER READY <port>` once it serves. The plain classpath and the
// DomainFile open are the two findings of phase 0 (plan §3): a class on the
// classpath of ghidra.Ghidra's own class loader cannot see Ghidra, and
// GhidraProject.openProgram keeps a standing transaction that one failed
// change turns into a lost session.

import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import ghidra.GhidraApplicationLayout;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.cmd.function.ApplyFunctionSignatureCmd;
import ghidra.app.script.GhidraState;
import ghidra.app.util.cparser.C.CParser;
import ghidra.app.util.cparser.C.CParserUtils;
import ghidra.app.script.ScriptControls;
import ghidra.base.project.GhidraProject;
import ghidra.framework.Application;
import ghidra.framework.HeadlessGhidraApplicationConfiguration;
import ghidra.framework.model.DomainFile;
import ghidra.program.model.address.Address;
import ghidra.program.model.data.DataType;
import ghidra.program.model.data.DataTypeConflictHandler;
import ghidra.program.model.data.DataUtilities;
import ghidra.program.model.data.FileDataTypeManager;
import ghidra.program.model.data.FunctionDefinitionDataType;
import ghidra.program.model.listing.CodeUnit;
import ghidra.program.model.listing.CommentType;
import ghidra.program.model.listing.Data;
import ghidra.program.model.listing.DataIterator;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.InstructionIterator;
import ghidra.program.model.listing.Parameter;
import ghidra.program.model.listing.Program;
import ghidra.program.model.pcode.HighFunction;
import ghidra.program.model.pcode.HighFunctionDBUtil;
import ghidra.program.model.pcode.HighSymbol;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.ReferenceIterator;
import ghidra.program.model.symbol.SourceType;
import ghidra.program.model.symbol.Symbol;
import ghidra.program.model.util.StringPropertyMap;
import ghidra.util.data.DataTypeParser;
import ghidra.util.task.TaskMonitor;

import java.io.File;
import java.nio.channels.FileChannel;
import java.nio.channels.FileLock;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.io.OutputStream;
import java.io.PrintWriter;
import java.net.InetSocketAddress;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.HashMap;
import java.util.Iterator;
import java.util.UUID;
import java.util.Map;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

public class Owner {
    static final int PROTOCOL = 1;
    /**
     * The jar this owner runs from, as its modification time in seconds: a
     * host compares it with the jar it would start now, and replaces an
     * owner that outlived a rebuild — a server restarted on new sources
     * while the owner ran on.
     */
    static final long BUILD = build();

    private static long build() {
        try {
            File jar = new File(Owner.class.getProtectionDomain().getCodeSource().getLocation().toURI());
            return jar.isFile() ? jar.lastModified() / 1000 : 0;
        } catch (Exception error) {
            return 0;
        }
    }

    private final Map<String, String> options;
    private GhidraProject project;
    private Program program;
    private DecompInterface decompiler;
    // The EDK2 archive the program was typed with, read-only: a type a
    // review names that the program does not hold yet comes from here.
    private FileDataTypeManager archive;
    // The types other reviews defined, as they were when this owner started:
    // a copy, so no owner ever holds the shared archive open (§6.5).
    private File reviewTypes;
    private File reviewTypesCopy;
    private FileDataTypeManager reviewArchive;
    private final Map<Address, DecompileResults> decompiled = new HashMap<>();
    private long decompiledAt = -1;
    private volatile long lastRequest = System.currentTimeMillis();
    // The write lease (§7.3): one holder at a time, renewed by every write.
    private String leaseToken;
    private String leaseHolder;
    private long leaseExpires;
    private long leaseTtl;
    // The review document of the last publish, for GET /v1/review.
    private Harvest.Document published;
    private final Gson gson = new GsonBuilder().disableHtmlEscaping().setPrettyPrinting().create();

    Owner(Map<String, String> options) {
        this.options = options;
    }

    public static void main(String[] args) throws Exception {
        Map<String, String> options = new HashMap<>();
        for (int i = 0; i + 1 < args.length; i += 2) {
            if (!args[i].startsWith("--")) throw new IllegalArgumentException("unexpected " + args[i]);
            options.put(args[i].substring(2), args[i + 1]);
        }
        for (String required : new String[] {"project-dir", "project-name", "program", "module", "project-id"}) {
            if (!options.containsKey(required)) throw new IllegalArgumentException("--" + required + " is required");
        }
        new Owner(options).run();
    }

    private void run() throws Exception {
        Application.initializeApplication(new GhidraApplicationLayout(),
                                          new HeadlessGhidraApplicationConfiguration());
        project = GhidraProject.openProject(options.get("project-dir"), options.get("project-name"));
        DomainFile file = project.getProject().getProjectData().getFile("/" + options.get("program"));
        if (file == null) throw new IllegalStateException("no program " + options.get("program") + " in the project");
        program = (Program) file.getDomainObject(this, true, false, TaskMonitor.DUMMY);
        decompiler = new DecompInterface();
        decompiler.openProgram(program);
        if (options.containsKey("types")) {
            archive = FileDataTypeManager.openFileArchive(new File(options.get("types")), false);
        }
        if (options.containsKey("review-types")) {
            String bits = program.getDefaultPointerSize() == 8 ? "X64" : "Ia32";
            reviewTypes = new File(options.get("review-types"), "review-types-" + bits + ".gdt");
            if (reviewTypes.isFile()) {
                reviewTypesCopy = File.createTempFile("review-types-", ".gdt");
                try (FileChannel channel = lockChannel(); FileLock lock = channel.lock()) {
                    Files.copy(reviewTypes.toPath(), reviewTypesCopy.toPath(), StandardCopyOption.REPLACE_EXISTING);
                }
                reviewArchive = FileDataTypeManager.openFileArchive(reviewTypesCopy, false);
            }
        }
        // What the program held before anyone reviewed it — the loader's
        // comments, ApplyUefi's types — so a harvest holds only the review.
        int transaction = program.startTransaction("baseline");
        boolean recorded = false;
        try {
            recorded = Harvest.recordBaseline(program);
        } finally {
            program.endTransaction(transaction, recorded);
        }
        if (recorded) program.save("baseline", TaskMonitor.DUMMY);

        int port = Integer.parseInt(options.getOrDefault("port", "0"));
        HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", port), 0);
        // One thread: every call sees the program between two changes, never
        // in the middle of one.
        server.setExecutor(Executors.newSingleThreadExecutor());
        server.createContext("/", this::handle);
        server.start();
        Runtime.getRuntime().addShutdownHook(new Thread(this::close));
        long idle = Long.parseLong(options.getOrDefault("idle", "0"));
        if (idle > 0) {
            Executors.newSingleThreadScheduledExecutor().scheduleAtFixedRate(() -> {
                if (System.currentTimeMillis() - lastRequest > idle * 1000) {
                    System.out.println("OWNER IDLE");
                    System.exit(0);
                }
            }, idle, Math.max(1, idle / 4), TimeUnit.SECONDS);
        }
        // An expired lease saves what its holder changed; it does not publish:
        // there is no client to hand an artifact to (§5.4). Run on the server's
        // own thread, so it never lands in the middle of a change.
        Executors.newSingleThreadScheduledExecutor().scheduleAtFixedRate(() -> {
            server.getExecutor().execute(this::expireLease);
        }, 5, 5, TimeUnit.SECONDS);
        System.out.println("OWNER READY " + server.getAddress().getPort());
        System.out.flush();
    }

    /** Save what changed and let the program go: on stop, idle and a signal. */
    private synchronized void close() {
        try {
            if (program == null) return;
            if (program.isChanged()) program.save("owner", TaskMonitor.DUMMY);
            if (decompiler != null) decompiler.dispose();
            if (archive != null) archive.close();
            if (reviewArchive != null) reviewArchive.close();
            if (reviewTypesCopy != null) reviewTypesCopy.delete();
            program.release(this);
            program = null;
            project.close();
        } catch (Exception error) {
            System.err.println("OWNER close: " + error);
        }
    }

    // MARK: - Requests

    private static final class Failure extends Exception {
        final int status;
        Failure(int status, String message) { super(message); this.status = status; }
    }

    private void handle(HttpExchange exchange) {
        lastRequest = System.currentTimeMillis();
        String method = exchange.getRequestMethod();
        String path = exchange.getRequestURI().getPath();
        Map<String, String> query = query(exchange.getRequestURI().getRawQuery());
        try {
            if (method.equals("GET")) {
                if (path.equals("/v1/hello")) { json(exchange, 200, hello()); return; }
                if (path.equals("/v1/functions")) { json(exchange, 200, functions(query)); return; }
                if (path.startsWith("/v1/function/")) { json(exchange, 200, function(path.substring(13))); return; }
                if (path.startsWith("/v1/disassembly/")) { json(exchange, 200, disassembly(path.substring(16))); return; }
                if (path.equals("/v1/xrefs")) { json(exchange, 200, xrefs(query)); return; }
                if (path.equals("/v1/data")) { json(exchange, 200, data(query, false)); return; }
                if (path.equals("/v1/strings")) { json(exchange, 200, data(query, true)); return; }
                if (path.equals("/v1/review")) { review(exchange); return; }
                if (path.equals("/v1/review/description")) { publishedDescription(exchange); return; }
                if (path.equals("/v1/description")) { json(exchange, 200, description()); return; }
                if (path.equals("/v1/type")) { json(exchange, 200, readType(query)); return; }
            } else if (method.equals("DELETE") && path.equals("/v1/lease")) {
                json(exchange, 200, release(exchange));
                return;
            } else if (method.equals("POST")) {
                if (path.equals("/v1/publish")) { publish(exchange); return; }
                if (path.equals("/v1/lease")) { lease(exchange, body(exchange)); return; }
                JsonObject write = switch (path) {
                    case "/v1/rename/function" -> write(exchange, this::renameFunction);
                    case "/v1/create/function" -> write(exchange, this::createFunction);
                    case "/v1/rename/variable" -> write(exchange, this::renameVariable);
                    case "/v1/set/signature" -> write(exchange, this::setSignature);
                    case "/v1/set/comment" -> write(exchange, this::setComment);
                    case "/v1/set/data" -> write(exchange, this::setData);
                    case "/v1/set/description" -> write(exchange, this::setDescription);
                    case "/v1/set/code-mode" -> write(exchange, this::setCodeMode);
                    case "/v1/type" -> write(exchange, this::addType);
                    case "/v1/save" -> write(exchange, body -> {
                        if (program.isChanged()) program.save("save", TaskMonitor.DUMMY);
                        JsonObject answer = identity();
                        answer.addProperty("saved", true);
                        return answer;
                    });
                    default -> null;
                };
                if (write != null) { json(exchange, 200, write); return; }
                if (path.equals("/v1/stop")) {
                    JsonObject answer = new JsonObject();
                    answer.addProperty("stopping", true);
                    json(exchange, 200, answer);
                    new Thread(() -> { close(); System.exit(0); }).start();
                    return;
                }
            }
            throw new Failure(404, method + " " + path + " is not a call of this bridge");
        } catch (Failure failure) {
            error(exchange, failure.status, failure.getMessage());
        } catch (Exception error) {
            error(exchange, 500, error.toString());
        }
    }

    private JsonObject hello() {
        JsonObject answer = identity();
        answer.addProperty("protocol", PROTOCOL);
        answer.addProperty("build", BUILD);
        answer.addProperty("ghidra", Application.getApplicationVersion());
        answer.addProperty("functions", program.getFunctionManager().getFunctionCount());
        answer.addProperty("changed", program.isChanged());
        answer.addProperty("modification", program.getModificationNumber());
        if (leaseToken != null) {
            answer.addProperty("lease_holder", leaseHolder);
            answer.addProperty("lease_expires_in", Math.max(0, (leaseExpires - System.currentTimeMillis()) / 1000));
        }
        return answer;
    }

    /** What every answer is about. */
    private JsonObject identity() {
        JsonObject answer = new JsonObject();
        answer.addProperty("module", options.get("module"));
        answer.addProperty("project", options.get("project-id"));
        answer.addProperty("program", program.getName());
        answer.addProperty("language", program.getLanguageID().toString());
        answer.addProperty("image_base", hex(program.getImageBase()));
        return answer;
    }

    private JsonObject functions(Map<String, String> query) throws Failure {
        int offset = integer(query, "offset", 0), limit = Math.min(integer(query, "limit", 500), 5000);
        JsonArray list = new JsonArray();
        int index = 0;
        boolean more = false;
        for (Function function : program.getFunctionManager().getFunctions(true)) {
            if (index++ < offset) continue;
            if (list.size() == limit) { more = true; break; }
            JsonObject item = new JsonObject();
            item.addProperty("entry", hex(function.getEntryPoint()));
            item.addProperty("name", function.getName());
            item.addProperty("name_source", function.getSymbol().getSource().toString());
            item.addProperty("size", function.getBody().getNumAddresses());
            item.addProperty("signature", function.getPrototypeString(false, false));
            list.add(item);
        }
        JsonObject answer = identity();
        answer.add("functions", list);
        if (more) answer.addProperty("next", offset + limit);
        return answer;
    }

    private JsonObject function(String text) throws Failure {
        Function function = functionAt(text);
        JsonObject answer = identity();
        answer.addProperty("entry", hex(function.getEntryPoint()));
        answer.addProperty("name", function.getName());
        answer.addProperty("name_source", function.getSymbol().getSource().toString());
        answer.addProperty("signature", function.getPrototypeString(false, false));
        JsonArray parameters = new JsonArray();
        for (Parameter parameter : function.getParameters()) {
            JsonObject item = new JsonObject();
            item.addProperty("ordinal", parameter.getOrdinal());
            item.addProperty("name", parameter.getName());
            item.addProperty("type", parameter.getDataType().getDisplayName());
            item.addProperty("storage", parameter.getVariableStorage().toString());
            parameters.add(item);
        }
        answer.add("parameters", parameters);
        DecompileResults results = decompile(function);
        HighFunction high = results == null ? null : results.getHighFunction();
        JsonArray locals = new JsonArray();
        if (high != null) {
            Iterator<HighSymbol> symbols = high.getLocalSymbolMap().getSymbols();
            while (symbols.hasNext()) {
                HighSymbol symbol = symbols.next();
                if (symbol.isParameter()) continue;
                JsonObject item = new JsonObject();
                item.addProperty("name", symbol.getName());
                DataType type = symbol.getDataType();
                item.addProperty("type", type == null ? null : type.getDisplayName());
                item.addProperty("storage", symbol.getStorage().toString());
                Address first = symbol.getPCAddress();
                item.addProperty("first_use", first == null ? null : hex(first));
                // Ghidra's names for unnamed locals renumber when another is
                // named; a client addresses a local by storage and first use.
                item.addProperty("named", symbol.getSymbol() != null);
                locals.add(item);
            }
        }
        answer.add("locals", locals);
        answer.addProperty("c", results != null && results.getDecompiledFunction() != null
                           ? results.getDecompiledFunction().getC() : null);
        if (results != null && !results.decompileCompleted()) {
            answer.addProperty("decompile_error", results.getErrorMessage());
        }
        return answer;
    }

    private JsonObject disassembly(String text) throws Failure {
        Function function = functionAt(text);
        JsonArray instructions = new JsonArray();
        InstructionIterator iterator = program.getListing().getInstructions(function.getBody(), true);
        while (iterator.hasNext()) {
            Instruction instruction = iterator.next();
            JsonObject item = new JsonObject();
            item.addProperty("address", hex(instruction.getAddress()));
            try {
                item.addProperty("bytes", hexBytes(instruction.getBytes()));
            } catch (Exception ignored) {
                item.addProperty("bytes", "");
            }
            item.addProperty("text", instruction.toString());
            // Code read as 16-bit in a 32-bit program (set/code-mode) says so.
            ghidra.program.model.lang.Register opsize = program.getProgramContext().getRegister("opsize");
            if (opsize != null && program.getDefaultPointerSize() == 4) {
                java.math.BigInteger mode = instruction.getValue(opsize, false);
                if (mode != null && mode.signum() == 0) item.addProperty("bits", 16);
            }
            JsonArray references = new JsonArray();
            for (Reference reference : instruction.getReferencesFrom()) {
                // A stack or register operand is not a place in the module.
                if (reference.getToAddress().isMemoryAddress()) references.add(reference(reference));
            }
            item.add("references", references);
            instructions.add(item);
        }
        JsonObject answer = identity();
        answer.addProperty("entry", hex(function.getEntryPoint()));
        answer.add("instructions", instructions);
        return answer;
    }

    private JsonObject xrefs(Map<String, String> query) throws Failure {
        JsonArray list = new JsonArray();
        if (query.containsKey("to")) {
            ReferenceIterator iterator = program.getReferenceManager().getReferencesTo(address(query.get("to")));
            while (iterator.hasNext()) list.add(reference(iterator.next()));
        } else if (query.containsKey("from")) {
            for (Reference reference : program.getReferenceManager().getReferencesFrom(address(query.get("from")))) {
                if (reference.getToAddress().isMemoryAddress()) list.add(reference(reference));
            }
        } else {
            throw new Failure(400, "xrefs needs to= or from=");
        }
        JsonObject answer = identity();
        answer.add("references", list);
        return answer;
    }

    private JsonObject data(Map<String, String> query, boolean strings) throws Failure {
        int offset = integer(query, "offset", 0), limit = Math.min(integer(query, "limit", 500), 5000);
        JsonArray list = new JsonArray();
        DataIterator iterator = program.getListing().getDefinedData(true);
        int index = 0;
        boolean more = false;
        while (iterator.hasNext()) {
            Data item = iterator.next();
            if (strings && !item.hasStringValue()) continue;
            if (index++ < offset) continue;
            if (list.size() == limit) { more = true; break; }
            JsonObject entry = new JsonObject();
            entry.addProperty("address", hex(item.getAddress()));
            entry.addProperty("type", item.getDataType().getDisplayName());
            entry.addProperty("length", item.getLength());
            if (item.getPrimarySymbol() != null) entry.addProperty("name", item.getPrimarySymbol().getName());
            if (strings) {
                Object value = item.getValue();
                entry.addProperty("value", value == null ? null : value.toString());
            }
            list.add(entry);
        }
        JsonObject answer = identity();
        answer.add(strings ? "strings" : "data", list);
        if (more) answer.addProperty("next", offset + limit);
        return answer;
    }

    /**
     * Saves the program if it changed, runs ExportCode on it here, and
     * answers with the artifact itself. The headers say what was exported;
     * the client stores the body and decides what that publish is.
     */
    private void publish(HttpExchange exchange) throws Exception {
        if (program.isChanged()) program.save("publish", TaskMonitor.DUMMY);
        File out = File.createTempFile("owner-export-", ".json");
        try {
            ExportCode export = new ExportCode();
            export.setScriptArgs(new String[] {out.getPath()});
            PrintWriter log = new PrintWriter(System.out, true);
            export.execute(new GhidraState(null, project.getProject(), program, null, null, null),
                           new ScriptControls(log, log, TaskMonitor.DUMMY));
            byte[] artifact = Files.readAllBytes(out.toPath());
            if (artifact.length == 0) throw new Failure(500, "the export wrote nothing");
            published = Harvest.of(program, options.get("module"), options.get("project-id"));
            java.util.List<String> conflicts = mergeReviewTypes();
            exchange.getResponseHeaders().set("Content-Type", "application/json");
            exchange.getResponseHeaders().set("X-Owner-Modification", Long.toString(program.getModificationNumber()));
            exchange.getResponseHeaders().set("X-Owner-Reviewed", Boolean.toString(published.reviewed));
            if (!conflicts.isEmpty()) {
                exchange.getResponseHeaders().set("X-Owner-Type-Conflicts", String.join(",", conflicts));
            }
            exchange.sendResponseHeaders(200, artifact.length);
            try (OutputStream body = exchange.getResponseBody()) { body.write(artifact); }
        } finally {
            out.delete();
        }
    }

    private FileChannel lockChannel() throws Exception {
        File lock = new File(reviewTypes.getPath() + ".lock");
        return FileChannel.open(lock.toPath(), StandardOpenOption.CREATE, StandardOpenOption.WRITE);
    }

    /**
     * Puts this review's types into the shared archive, under its lock, for
     * the modules opened after it. A type the archive already has under the
     * name is left alone when it is the same, and reported when it is not:
     * the program keeps its own, and choosing is a person's (§16.5). The
     * lock is held for the length of the merge, a second or so.
     */
    private java.util.List<String> mergeReviewTypes() throws Exception {
        java.util.List<String> conflicts = new java.util.ArrayList<>();
        java.util.TreeMap<String, String> mine = Harvest.reviewTypes(program);
        if (reviewTypes == null || mine.isEmpty()) return conflicts;
        reviewTypes.getParentFile().mkdirs();
        try (FileChannel channel = lockChannel(); FileLock lock = channel.lock()) {
            FileDataTypeManager shared = reviewTypes.isFile()
                ? FileDataTypeManager.openFileArchive(reviewTypes, true)
                : FileDataTypeManager.createFileArchive(reviewTypes, program.getLanguageID(),
                      program.getCompilerSpec().getCompilerSpecID());
            try {
                boolean changed = false;
                int transaction = shared.startTransaction("review types of " + options.get("module"));
                try {
                    for (String name : mine.keySet()) {
                        java.util.List<DataType> here = new java.util.ArrayList<>();
                        program.getDataTypeManager().findDataTypes(name, here);
                        if (here.isEmpty()) continue;
                        java.util.List<DataType> there = new java.util.ArrayList<>();
                        shared.findDataTypes(name, there);
                        if (there.isEmpty()) {
                            shared.resolve(here.get(0), DataTypeConflictHandler.KEEP_HANDLER);
                            changed = true;
                        } else if (!there.get(0).isEquivalent(here.get(0))) {
                            conflicts.add(name);
                        }
                    }
                } finally {
                    shared.endTransaction(transaction, true);
                }
                if (changed) shared.save();
            } finally {
                shared.close();
            }
        }
        return conflicts;
    }

    /** The review document harvested by the last publish. */
    private void review(HttpExchange exchange) throws Exception {
        if (published == null) throw new Failure(409, "nothing was published by this owner yet");
        exchange.getResponseHeaders().set("Content-Type", "application/json");
        exchange.getResponseHeaders().set("X-Owner-Reviewed", Boolean.toString(published.reviewed));
        exchange.sendResponseHeaders(200, published.bytes.length);
        try (OutputStream body = exchange.getResponseBody()) { body.write(published.bytes); }
    }

    /**
     * The description as the last publish took it, as Markdown; 204 when it
     * had none. The client stores it as an object of its own.
     */
    private void publishedDescription(HttpExchange exchange) throws Exception {
        if (published == null) throw new Failure(409, "nothing was published by this owner yet");
        if (published.description == null) {
            exchange.sendResponseHeaders(204, -1);
            exchange.close();
            return;
        }
        exchange.getResponseHeaders().set("Content-Type", "text/markdown; charset=utf-8");
        exchange.sendResponseHeaders(200, published.description.length);
        try (OutputStream body = exchange.getResponseBody()) { body.write(published.description); }
    }

    /** The description as the program holds it now, with its sections. */
    private JsonObject description() {
        String text = Harvest.description(program);
        JsonObject answer = identity();
        if (text == null) {
            answer.add("text", com.google.gson.JsonNull.INSTANCE);
        } else {
            answer.addProperty("text", text);
        }
        JsonArray sections = new JsonArray();
        Harvest.sections(text).forEach(sections::add);
        answer.add("sections", sections);
        answer.addProperty("bytes", text == null ? 0 : text.getBytes(StandardCharsets.UTF_8).length);
        return answer;
    }

    /**
     * The module's description, whole or one `## ` section of it: `text` is
     * the Markdown (empty clears it, or removes the section), `section` the
     * heading whose body it replaces.
     */
    private JsonObject setDescription(JsonObject body) throws Exception {
        if (!body.has("text") || body.get("text").isJsonNull()) throw new Failure(400, "text is required");
        String text = body.get("text").getAsString();
        String section = string(body, "section", null);
        String next;
        if (section == null || section.isEmpty()) {
            next = Harvest.normalized(text);
        } else {
            String heading = section.startsWith("## ") ? section.substring(3).trim() : section.trim();
            if (heading.isEmpty() || heading.contains("\n")) throw new Failure(400, "section is one heading's words");
            next = Harvest.replaceSection(Harvest.description(program), heading, text);
        }
        if (next != null && next.getBytes(StandardCharsets.UTF_8).length > Harvest.DESCRIPTION_LIMIT) {
            throw new Failure(413, "a description is at most " + Harvest.DESCRIPTION_LIMIT / 1024 + " KiB");
        }
        Harvest.setDescription(program, next);
        return description();
    }

    // MARK: - The lease

    private void lease(HttpExchange exchange, JsonObject body) throws Exception {
        expireLease();
        String holder = string(body, "holder", "a client");
        // The same holder asking again is a host that lost its token — a
        // server restarted while this owner ran on: it takes the lease over.
        if (leaseToken != null && leaseToken.length() > 0 && holder.equals(leaseHolder)) {
            System.out.println("OWNER LEASE TAKEN OVER by " + holder);
            if (program.isChanged()) program.save("lease taken over by " + holder, TaskMonitor.DUMMY);
            leaseToken = null;
        }
        if (leaseToken != null) {
            JsonObject refused = new JsonObject();
            refused.addProperty("error", "the module is leased to " + leaseHolder);
            refused.addProperty("holder", leaseHolder);
            refused.addProperty("expires_in", (leaseExpires - System.currentTimeMillis()) / 1000);
            json(exchange, 409, refused);
            return;
        }
        leaseTtl = Math.max(30, Math.min(integer(body, "ttl", 900), 86400)) * 1000L;
        leaseToken = UUID.randomUUID().toString();
        leaseHolder = holder;
        leaseExpires = System.currentTimeMillis() + leaseTtl;
        System.out.println("OWNER LEASE " + holder);
        JsonObject answer = identity();
        answer.addProperty("token", leaseToken);
        answer.addProperty("expires_in", leaseTtl / 1000);
        json(exchange, 200, answer);
    }

    private JsonObject release(HttpExchange exchange) throws Exception {
        requireLease(exchange);
        if (program.isChanged()) program.save("lease released by " + leaseHolder, TaskMonitor.DUMMY);
        System.out.println("OWNER RELEASE " + leaseHolder);
        leaseToken = null;
        leaseHolder = null;
        JsonObject answer = identity();
        answer.addProperty("released", true);
        return answer;
    }

    private void expireLease() {
        if (leaseToken == null || System.currentTimeMillis() < leaseExpires) return;
        System.out.println("OWNER EXPIRED " + leaseHolder);
        try {
            if (program.isChanged()) program.save("lease of " + leaseHolder + " expired", TaskMonitor.DUMMY);
        } catch (Exception error) {
            System.err.println("OWNER save on expiry: " + error);
        }
        leaseToken = null;
        leaseHolder = null;
    }

    private void requireLease(HttpExchange exchange) throws Failure {
        expireLease();
        String token = exchange.getRequestHeaders().getFirst("X-Lease");
        if (leaseToken == null) throw new Failure(403, "take the write lease first: POST /v1/lease");
        if (!leaseToken.equals(token)) throw new Failure(403, "the module is leased to " + leaseHolder);
        leaseExpires = System.currentTimeMillis() + leaseTtl;
    }

    // MARK: - Writes

    private interface Change {
        JsonObject apply(JsonObject body) throws Exception;
    }

    /**
     * One change: under the lease, in a transaction of its own that is
     * committed only if the change succeeded. A refused change rolls back
     * itself and nothing before it — the lesson of phase 0.
     */
    private JsonObject write(HttpExchange exchange, Change change) throws Exception {
        requireLease(exchange);
        JsonObject body = body(exchange);
        int transaction = program.startTransaction(exchange.getRequestURI().getPath());
        boolean done = false;
        try {
            JsonObject answer = change.apply(body);
            done = true;
            System.out.println("OWNER CHANGE " + leaseHolder + " " + exchange.getRequestURI().getPath()
                               + " " + body);
            return answer;
        } finally {
            program.endTransaction(transaction, done);
        }
    }

    private JsonObject renameFunction(JsonObject body) throws Exception {
        Function function = functionAt(required(body, "address"));
        String name = required(body, "name");
        // Ghidra takes `*Name` for a name; C, the panel and a reader do not.
        if (!name.matches("[A-Za-z_][A-Za-z0-9_]*")) throw new Failure(400, name + " is not a C identifier");
        // Ghidra would make a duplicate `Foo_1`; a client gets the refusal.
        for (Symbol other : program.getSymbolTable().getGlobalSymbols(name)) {
            if (!other.getAddress().equals(function.getEntryPoint())) {
                throw new Failure(409, name + " already names " + hex(other.getAddress()));
            }
        }
        try {
            function.setName(name, SourceType.USER_DEFINED);
        } catch (Exception error) {
            throw new Failure(400, error.getMessage());
        }
        why(function.getEntryPoint(), body);
        JsonObject answer = identity();
        answer.addProperty("entry", hex(function.getEntryPoint()));
        answer.addProperty("name", function.getName());
        return answer;
    }

    /**
     * A function at `address` where Ghidra made none: code reached only
     * through a table — a services table's slot, a PPI's member — that no
     * call names. The instructions are disassembled first when they are not
     * yet; `name`, when given, names it as a rename would. One already there
     * is answered as it is.
     */
    private JsonObject createFunction(JsonObject body) throws Exception {
        Address at = address(required(body, "address"));
        Function function = program.getFunctionManager().getFunctionAt(at);
        boolean created = false;
        if (function == null) {
            if (program.getListing().getInstructionAt(at) == null) {
                if (program.getListing().getDefinedDataContaining(at) != null) {
                    throw new Failure(409, hex(at) + " is defined data, not code");
                }
                new ghidra.app.cmd.disassemble.DisassembleCommand(at, null, true).applyTo(program, TaskMonitor.DUMMY);
                if (program.getListing().getInstructionAt(at) == null) {
                    throw new Failure(400, "no instruction decodes at " + hex(at));
                }
            }
            ghidra.app.cmd.function.CreateFunctionCmd command = new ghidra.app.cmd.function.CreateFunctionCmd(at);
            if (!command.applyTo(program, TaskMonitor.DUMMY)) {
                throw new Failure(400, "Ghidra made no function at " + hex(at)
                    + (command.getStatusMsg() == null ? "" : ": " + command.getStatusMsg()));
            }
            function = program.getFunctionManager().getFunctionAt(at);
            created = true;
        }
        if (body.has("name") && !body.get("name").isJsonNull()) {
            JsonObject rename = body.deepCopy();
            rename.addProperty("address", hex(at));
            renameFunction(rename);
        }
        JsonObject answer = identity();
        answer.addProperty("entry", hex(function.getEntryPoint()));
        answer.addProperty("name", function.getName());
        answer.addProperty("created", created);
        answer.addProperty("size", function.getBody().getNumAddresses());
        return answer;
    }

    /**
     * The code in [start, end) read as 16-bit or as 32-bit x86. A 32-bit
     * program decodes the reset vector's real-mode code as 32-bit, which
     * reads it wrongly: the operand and address size live in the x86
     * context (`opsize`, `addrsize`), not in the bytes. The instructions in
     * the range are cleared, the context set, the range disassembled again
     * from `start` without leaving it, and every function that lost or
     * gained instructions has its body fixed. The segment model is left as
     * it is: an address is still an offset, not segment × 16 + offset.
     */
    private JsonObject setCodeMode(JsonObject body) throws Exception {
        Address start = address(required(body, "start"));
        Address end = address(required(body, "end"));
        int bits = integer(body, "bits", 0);
        if (bits != 16 && bits != 32) throw new Failure(400, "bits is 16 or 32");
        if (end.compareTo(start) <= 0) throw new Failure(400, "end is past start: the range is [start, end)");
        Address last = end.subtract(1);
        if (!program.getMemory().contains(start, last)) {
            throw new Failure(400, hex(start) + ".." + hex(end) + " is not all in the program's memory");
        }
        ghidra.program.model.lang.Register addrsize = program.getProgramContext().getRegister("addrsize");
        ghidra.program.model.lang.Register opsize = program.getProgramContext().getRegister("opsize");
        if (addrsize == null || opsize == null) {
            throw new Failure(400, program.getLanguageID() + " has no x86 operand-size context");
        }
        ghidra.program.model.address.AddressSet range = new ghidra.program.model.address.AddressSet(start, last);

        // Instructions that reach into the range from before it go too:
        // their bytes are the range's.
        java.util.Set<Address> touched = new java.util.TreeSet<>();
        Instruction before = program.getListing().getInstructionContaining(start);
        Address clearFrom = before != null ? before.getMinAddress() : start;
        Instruction after = program.getListing().getInstructionContaining(last);
        Address clearTo = after != null ? after.getMaxAddress() : last;
        for (Instruction instruction : program.getListing().getInstructions(
                 new ghidra.program.model.address.AddressSet(clearFrom, clearTo), true)) {
            Function owner = program.getFunctionManager().getFunctionContaining(instruction.getMinAddress());
            if (owner != null) touched.add(owner.getEntryPoint());
        }
        if (program.getListing().getDefinedDataContaining(start) != null
            || program.getListing().getDefinedData(range, true).hasNext()) {
            throw new Failure(409, "defined data lies in " + hex(start) + ".." + hex(end) + ": clear it first");
        }
        program.getListing().clearCodeUnits(clearFrom, clearTo, false);

        java.math.BigInteger value = java.math.BigInteger.valueOf(bits == 16 ? 0 : 1);
        program.getProgramContext().setValue(addrsize, start, last, value);
        program.getProgramContext().setValue(opsize, start, last, value);

        ghidra.app.cmd.disassemble.DisassembleCommand disassemble =
            new ghidra.app.cmd.disassemble.DisassembleCommand(new ghidra.program.model.address.AddressSet(start), range, true);
        disassemble.applyTo(program, TaskMonitor.DUMMY);
        // What the range lost before `start` and after its last instruction
        // is decoded again in the mode that was there.
        if (clearFrom.compareTo(start) < 0) {
            new ghidra.app.cmd.disassemble.DisassembleCommand(clearFrom, null, true).applyTo(program, TaskMonitor.DUMMY);
        }

        Function atStart = program.getFunctionManager().getFunctionAt(start);
        if (atStart != null) touched.add(start);
        JsonArray functions = new JsonArray();
        for (Address entry : touched) {
            Function function = program.getFunctionManager().getFunctionAt(entry);
            if (function == null) continue;
            ghidra.app.cmd.function.CreateFunctionCmd.fixupFunctionBody(program, function, TaskMonitor.DUMMY);
            functions.add(hex(entry));
        }
        int decoded = 0;
        for (Instruction instruction : program.getListing().getInstructions(range, true)) decoded++;
        if (decoded == 0) throw new Failure(400, "no instruction decodes at " + hex(start) + " as " + bits + "-bit code");
        why(start, body);

        JsonObject answer = identity();
        answer.addProperty("start", hex(start));
        answer.addProperty("end", hex(end));
        answer.addProperty("bits", bits);
        answer.addProperty("instructions", decoded);
        answer.add("functions", functions);
        return answer;
    }

    /** Who made a name and why, beside the reason ApplyUefi gives its own. */
    private void why(Address address, JsonObject body) throws Exception {
        String reason = string(body, "reason", null);
        String by = string(body, "by", "agent");
        if (!by.equals("agent") && !by.equals("person")) throw new Failure(400, "by is agent or person");
        StringPropertyMap reasons = propertyMap(Harvest.REASON);
        if (reason != null) reasons.add(address, reason); else reasons.remove(address);
        propertyMap(Harvest.BY).add(address, by);
    }

    private StringPropertyMap propertyMap(String name) throws Exception {
        StringPropertyMap map = program.getUsrPropertyManager().getStringPropertyMap(name);
        return map != null ? map : program.getUsrPropertyManager().createStringPropertyMap(name);
    }

    /**
     * A parameter (by ordinal, or by storage) or a local (by storage and, for
     * a register, its first use), named and perhaps typed through the
     * decompiler, which commits it to the program. Ghidra's own names for
     * unnamed locals renumber, so they are never accepted as an address.
     */
    private JsonObject renameVariable(JsonObject body) throws Exception {
        Function function = functionAt(required(body, "function"));
        String name = required(body, "name");
        String storage = string(body, "storage", null);
        String firstUse = string(body, "first_use", null);
        Integer ordinal = body.has("ordinal") && !body.get("ordinal").isJsonNull() ? body.get("ordinal").getAsInt() : null;
        if (storage == null && ordinal == null) throw new Failure(400, "name the variable by storage (and first_use) or ordinal");
        DataType type = body.has("type") && !body.get("type").isJsonNull() ? type(body.get("type").getAsString()) : null;
        DecompileResults results = decompile(function);
        HighFunction high = results == null ? null : results.getHighFunction();
        if (high == null) throw new Failure(500, "the function does not decompile");
        HighSymbol match = null;
        Iterator<HighSymbol> symbols = high.getLocalSymbolMap().getSymbols();
        while (symbols.hasNext()) {
            HighSymbol symbol = symbols.next();
            boolean fits;
            if (ordinal != null) {
                fits = symbol.isParameter() && symbol.getCategoryIndex() == ordinal;
            } else {
                // A first use, when given, has to match whatever the variable is:
                // a parameter shares its register with locals of the body.
                fits = symbol.getStorage().toString().equals(storage)
                    && (firstUse == null
                        || (symbol.getPCAddress() != null && hex(symbol.getPCAddress()).equalsIgnoreCase(firstUse)));
            }
            if (!fits) continue;
            if (match != null) throw new Failure(409, "several variables are stored in " + storage + "; give first_use");
            match = symbol;
        }
        if (match == null) throw new Failure(404, "no such variable in " + function.getName());
        try {
            HighFunctionDBUtil.updateDBVariable(match, name, type, SourceType.USER_DEFINED);
        } catch (Exception error) {
            throw new Failure(400, error.getMessage());
        }
        // The storage as it is now: a decompiler temporary becomes HASH:… once
        // it is named, and that is what names it from here on.
        decompiled.remove(function.getEntryPoint());
        JsonObject answer = identity();
        answer.addProperty("function", hex(function.getEntryPoint()));
        answer.addProperty("name", name);
        HighFunction after = decompile(function).getHighFunction();
        if (after != null) {
            Iterator<HighSymbol> now = after.getLocalSymbolMap().getSymbols();
            while (now.hasNext()) {
                HighSymbol symbol = now.next();
                if (!symbol.getName().equals(name)) continue;
                answer.addProperty("storage", symbol.getStorage().toString());
                Address first = symbol.getPCAddress();
                answer.addProperty("first_use", first == null ? null : hex(first));
                answer.addProperty("parameter", symbol.isParameter());
            }
        }
        return answer;
    }

    private JsonObject setSignature(JsonObject body) throws Exception {
        Function function = functionAt(required(body, "address"));
        String text = edk2(required(body, "signature"));
        // Ghidra's signature parser misreads the pointers of the return type
        // when the function's name is already a symbol of the program (`T *`
        // came back as `T`, or as `T **`). The text is parsed under a name
        // nothing has, and the real one is set afterwards.
        java.util.regex.Matcher named = java.util.regex.Pattern
            .compile("([A-Za-z_][A-Za-z0-9_]*)\\s*\\(").matcher(text);
        if (!named.find()) throw new Failure(400, "the signature names no function");
        String name = named.group(1);
        String parsed = text.substring(0, named.start(1)) + " __byteripper_signature"
                        + text.substring(named.end(1));
        importTypes(parsed);
        FunctionDefinitionDataType signature;
        try {
            signature = CParserUtils.parseSignature((ghidra.app.services.DataTypeManagerService) null,
                                                    program, parsed, false);
        } catch (Exception error) {
            throw new Failure(400, "the signature does not parse: " + error.getMessage());
        }
        if (signature == null) throw new Failure(400, "the signature does not parse");
        signature.setName(name);
        ApplyFunctionSignatureCmd command =
            new ApplyFunctionSignatureCmd(function.getEntryPoint(), signature, SourceType.USER_DEFINED);
        if (!command.applyTo(program)) throw new Failure(400, command.getStatusMsg());
        // The command renames only a function Ghidra named; a signature's name
        // is the reviewer's either way.
        if (!function.getName().equals(name)) {
            try {
                function.setName(name, SourceType.USER_DEFINED);
            } catch (Exception error) {
                throw new Failure(409, error.getMessage());
            }
        }
        if (body.has("storage") || body.has("return_storage")) applyStorage(function, body);
        if (!function.getName().equals(signature.getName()) || function.getSymbol().getSource() == SourceType.USER_DEFINED) {
            why(function.getEntryPoint(), body);
        }
        JsonObject answer = identity();
        answer.addProperty("entry", hex(function.getEntryPoint()));
        answer.addProperty("signature", function.getPrototypeString(false, false));
        if (function.hasCustomVariableStorage()) {
            JsonArray storage = new JsonArray();
            for (Parameter parameter : function.getParameters()) storage.add(parameter.getVariableStorage().toString());
            answer.add("storage", storage);
            answer.addProperty("return_storage", function.getReturn().getVariableStorage().toString());
        }
        return answer;
    }

    /**
     * Where each parameter and the result really are, for a function no
     * calling convention describes: a linker's clone that takes its argument
     * in EDX, or hands its result back through a pointer in ECX. `storage`
     * has one entry per parameter of the signature just applied, written as
     * `ghidra_function` lists storage — `EDX:4`, `Stack[0x4]:4`, `EDX:4,EAX:4`
     * for a value split over two; `return_storage` the result's, `EAX:4` by
     * default as the convention put it.
     */
    private void applyStorage(Function function, JsonObject body) throws Exception {
        Parameter[] current = function.getParameters();
        java.util.List<ghidra.program.model.listing.Variable> parameters = new java.util.ArrayList<>();
        JsonArray storage = body.has("storage") && body.get("storage").isJsonArray()
            ? body.getAsJsonArray("storage") : null;
        if (storage != null && storage.size() != current.length) {
            throw new Failure(400, "storage names " + storage.size() + " places for " + current.length
                + " parameters of the signature");
        }
        for (int index = 0; index < current.length; index++) {
            ghidra.program.model.listing.VariableStorage place = storage == null
                ? current[index].getVariableStorage()
                : storage(storage.get(index).getAsString(), current[index].getLength());
            parameters.add(new ghidra.program.model.listing.ParameterImpl(
                current[index].getName(), current[index].getDataType(), place, program, SourceType.USER_DEFINED));
        }
        ghidra.program.model.listing.Parameter result = function.getReturn();
        ghidra.program.model.listing.VariableStorage resultPlace = body.has("return_storage")
            ? storage(body.get("return_storage").getAsString(), result.getLength())
            : result.getVariableStorage();
        ghidra.program.model.listing.ReturnParameterImpl returned =
            new ghidra.program.model.listing.ReturnParameterImpl(result.getDataType(), resultPlace, program);
        try {
            function.updateFunction(function.getCallingConventionName(), returned, parameters,
                Function.FunctionUpdateType.CUSTOM_STORAGE, true, SourceType.USER_DEFINED);
        } catch (Exception error) {
            throw new Failure(400, "the storage does not fit: " + error.getMessage());
        }
    }

    /** `EDX:4`, `Stack[0x4]:4`, `EDX:4,EAX:4` (high part first), or `void`. */
    private ghidra.program.model.listing.VariableStorage storage(String text, int length) throws Exception {
        text = text.trim();
        if (text.isEmpty() || text.equalsIgnoreCase("void")) return ghidra.program.model.listing.VariableStorage.VOID_STORAGE;
        java.util.List<ghidra.program.model.pcode.Varnode> pieces = new java.util.ArrayList<>();
        int total = 0;
        for (String piece : text.split(",")) {
            piece = piece.trim();
            java.util.regex.Matcher stack = java.util.regex.Pattern
                .compile("(?i)stack\\[(-?)(0x[0-9a-f]+|\\d+)\\](?::(\\d+))?").matcher(piece);
            if (stack.matches()) {
                long offset = Long.decode(stack.group(2));
                if (!stack.group(1).isEmpty()) offset = -offset;
                int size = stack.group(3) != null ? Integer.parseInt(stack.group(3)) : length;
                pieces.add(new ghidra.program.model.pcode.Varnode(
                    program.getAddressFactory().getStackSpace().getAddress(offset), size));
                total += size;
                continue;
            }
            String[] parts = piece.split(":");
            ghidra.program.model.lang.Register register = program.getRegister(parts[0].trim());
            if (register == null) throw new Failure(400, "no register or stack place " + piece);
            int size = parts.length > 1 ? Integer.parseInt(parts[1].trim()) : register.getMinimumByteSize();
            pieces.add(new ghidra.program.model.pcode.Varnode(register.getAddress(), size));
            total += size;
        }
        if (length > 0 && total != length) {
            throw new Failure(400, text + " holds " + total + " bytes for a value of " + length);
        }
        return new ghidra.program.model.listing.VariableStorage(program,
            pieces.toArray(new ghidra.program.model.pcode.Varnode[0]));
    }

    private JsonObject setComment(JsonObject body) throws Exception {
        Address address = address(required(body, "address"));
        CommentType kind;
        try {
            kind = CommentType.valueOf(string(body, "kind", "pre").toUpperCase());
        } catch (IllegalArgumentException error) {
            throw new Failure(400, "kind is pre, post, eol, plate or repeatable");
        }
        CodeUnit unit = program.getListing().getCodeUnitAt(address);
        if (unit == null) throw new Failure(404, "nothing starts at " + hex(address));
        String text = string(body, "text", null);
        unit.setComment(kind, text == null || text.isEmpty() ? null : text);
        JsonObject answer = identity();
        answer.addProperty("address", hex(address));
        answer.addProperty("kind", kind.name().toLowerCase());
        return answer;
    }

    private JsonObject setData(JsonObject body) throws Exception {
        Address address = address(required(body, "address"));
        if (body.has("type") && !body.get("type").isJsonNull()) {
            DataType type = type(body.get("type").getAsString());
            DataUtilities.createData(program, address, type, -1,
                                     DataUtilities.ClearDataMode.CLEAR_ALL_CONFLICT_DATA);
        }
        String name = string(body, "name", null);
        if (name != null) {
            Symbol primary = program.getSymbolTable().getPrimarySymbol(address);
            try {
                if (primary != null && !primary.isDynamic()) primary.setName(name, SourceType.USER_DEFINED);
                else program.getSymbolTable().createLabel(address, name, SourceType.USER_DEFINED);
            } catch (Exception error) {
                throw new Failure(400, error.getMessage());
            }
        }
        JsonObject answer = identity();
        answer.addProperty("address", hex(address));
        Data datum = program.getListing().getDefinedDataAt(address);
        if (datum != null) answer.addProperty("type", datum.getDataType().getDisplayName());
        return answer;
    }

    /**
     * `typedef enum { … } NAME;` with the tag `_NAME` written in. Ghidra's C
     * parser names an anonymous enum by where it starts in the text, so two
     * of them, each first in its own call, are the same type to the program:
     * the second replaced the first's values, and the decompiler wrote an
     * EFI_STATUS as DEBUG_* flags. A structure or union is tagged the same.
     */
    static String tagAnonymous(String c) {
        java.util.regex.Matcher open = java.util.regex.Pattern
            .compile("\\btypedef\\s+(struct|union|enum)\\s*\\{").matcher(c);
        java.util.regex.Pattern name = java.util.regex.Pattern.compile("\\s*([A-Za-z_][A-Za-z0-9_]*)");
        StringBuilder out = new StringBuilder();
        int from = 0;
        while (open.find(from)) {
            int brace = open.end() - 1;
            int depth = 0, close = -1;
            for (int i = brace; i < c.length() && close < 0; i++) {
                if (c.charAt(i) == '{') depth++;
                else if (c.charAt(i) == '}' && --depth == 0) close = i;
            }
            if (close < 0) break;
            java.util.regex.Matcher named = name.matcher(c).region(close + 1, c.length());
            out.append(c, from, brace);
            if (named.lookingAt()) out.append('_').append(named.group(1)).append(' ');
            out.append(c, brace, close + 1);
            from = close + 1;
        }
        out.append(c.substring(from));
        return out.toString();
    }

    /** A structure, union, enum or typedef from C, into the program. */
    private JsonObject addType(JsonObject body) throws Exception {
        String c = required(body, "c");
        // The fields may name what only an archive holds — `CHAR8`, a PI
        // structure, another review's type — as a signature may.
        importTypes(c);
        DataType parsed;
        try {
            parsed = new CParser(program.getDataTypeManager(), true, null).parse(tagAnonymous(c));
        } catch (Exception error) {
            throw new Failure(400, "the C does not parse: " + error.getMessage());
        }
        if (parsed == null) throw new Failure(400, "the C declares no type");
        DataType resolved = program.getDataTypeManager().resolve(parsed, DataTypeConflictHandler.REPLACE_HANDLER);
        Harvest.recordType(program, resolved.getName(), c);
        JsonObject answer = identity();
        answer.addProperty("name", resolved.getName());
        answer.addProperty("path", resolved.getPathName());
        return answer;
    }

    /**
     * A type by name as the program holds it, as the shared review archive
     * holds it now — read afresh, since another owner may have published
     * into it since this one opened — and as EDK2's archive holds it, each
     * as C and as fields with their offsets: what a review needs to bring
     * its own definition in line with the one `publish` reported.
     */
    private JsonObject readType(Map<String, String> query) throws Exception {
        String name = query.get("name");
        if (name == null || name.isBlank()) throw new Failure(400, "name the type: ?name=");
        name = name.trim();
        JsonObject answer = identity();
        answer.addProperty("name", name);
        DataType here = find(program.getDataTypeManager(), name);
        answer.add("program", TypeText.describe(here));
        if (reviewTypes != null && reviewTypes.isFile()) {
            File copy = File.createTempFile("review-types-", ".gdt");
            try {
                try (FileChannel channel = lockChannel(); FileLock lock = channel.lock()) {
                    Files.copy(reviewTypes.toPath(), copy.toPath(), StandardCopyOption.REPLACE_EXISTING);
                }
                FileDataTypeManager shared = FileDataTypeManager.openFileArchive(copy, false);
                try {
                    DataType there = find(shared, name);
                    answer.add("shared", TypeText.describe(there));
                    if (here != null && there != null) answer.addProperty("same", there.isEquivalent(here));
                } finally {
                    shared.close();
                }
            } finally {
                copy.delete();
            }
        } else {
            answer.add("shared", com.google.gson.JsonNull.INSTANCE);
        }
        answer.add("edk2", TypeText.describe(archive == null ? null : find(archive, name)));
        return answer;
    }

    private static DataType find(ghidra.program.model.data.DataTypeManager manager, String name) {
        java.util.List<DataType> found = new java.util.ArrayList<>();
        manager.findDataTypes(name, found);
        return found.isEmpty() ? null : found.get(0);
    }

    /**
     * Brings into the program every type `text` names that the program does
     * not hold but the EDK2 archive does — `VOID`, a protocol, a PI table —
     * so a signature or a variable can be written the way EDK2 spells it.
     */
    private void importTypes(String text) {
        if (archive == null && reviewArchive == null) return;
        java.util.regex.Matcher words = java.util.regex.Pattern.compile("[A-Za-z_][A-Za-z0-9_]*").matcher(text);
        while (words.find()) {
            String word = words.group();
            java.util.List<DataType> here = new java.util.ArrayList<>();
            program.getDataTypeManager().findDataTypes(word, here);
            if (!here.isEmpty()) continue;
            // Another review's type first, then EDK2's.
            for (FileDataTypeManager source : new FileDataTypeManager[] {reviewArchive, archive}) {
                if (source == null) continue;
                java.util.List<DataType> there = new java.util.ArrayList<>();
                source.findDataTypes(word, there);
                if (!there.isEmpty()) {
                    program.getDataTypeManager().resolve(there.get(0), DataTypeConflictHandler.DEFAULT_HANDLER);
                    break;
                }
            }
        }
    }

    /**
     * EDK2's spelling without its macros, which are not types: `VOID` is
     * `void`, `CONST` is `const`, and `IN`, `OUT`, `OPTIONAL`, `EFIAPI` say
     * nothing a C parser reads.
     */
    static String edk2(String text) {
        return text.replaceAll("\\bVOID\\b", "void")
                   .replaceAll("\\bCONST\\b", "const")
                   .replaceAll("\\b(IN|OUT|OPTIONAL|EFIAPI)\\b", " ")
                   .replaceAll("\\s+", " ").trim();
    }

    private DataType type(String text) throws Failure {
        text = edk2(text);
        importTypes(text);
        try {
            DataType type = new DataTypeParser(program.getDataTypeManager(), program.getDataTypeManager(),
                                               null, DataTypeParser.AllowedDataTypes.ALL).parse(text);
            if (type == null) throw new Failure(400, "no type " + text);
            return type;
        } catch (Failure failure) {
            throw failure;
        } catch (Exception error) {
            throw new Failure(400, "no type " + text + ": " + error.getMessage());
        }
    }

    // MARK: - Program

    private Function functionAt(String text) throws Failure {
        Address address = address(text);
        Function function = program.getFunctionManager().getFunctionAt(address);
        if (function == null) function = program.getFunctionManager().getFunctionContaining(address);
        if (function == null) throw new Failure(404, "no function at " + text);
        return function;
    }

    private Address address(String text) throws Failure {
        String digits = text.startsWith("0x") || text.startsWith("0X") ? text.substring(2) : text;
        try {
            long offset = Long.parseUnsignedLong(digits, 16);
            return program.getAddressFactory().getDefaultAddressSpace().getAddress(offset);
        } catch (Exception error) {
            throw new Failure(400, text + " is not an address");
        }
    }

    /**
     * A function's decompilation, kept until the program changes: a rename
     * changes the C of the function and of every caller, so any change
     * empties the whole cache, and a function is decompiled again only when
     * it is read.
     */
    private DecompileResults decompile(Function function) {
        long now = program.getModificationNumber();
        if (now != decompiledAt) {
            decompiled.clear();
            decompiledAt = now;
        }
        return decompiled.computeIfAbsent(function.getEntryPoint(),
            entry -> decompiler.decompileFunction(function, 120, TaskMonitor.DUMMY));
    }

    private JsonObject reference(Reference reference) {
        JsonObject item = new JsonObject();
        item.addProperty("from", hex(reference.getFromAddress()));
        item.addProperty("to", hex(reference.getToAddress()));
        item.addProperty("type", reference.getReferenceType().getName());
        Function from = program.getFunctionManager().getFunctionContaining(reference.getFromAddress());
        if (from != null) item.addProperty("function", hex(from.getEntryPoint()));
        return item;
    }

    // MARK: - Plumbing

    private static String hex(Address address) {
        return "0x" + Long.toHexString(address.getOffset()).toUpperCase();
    }

    private static String hexBytes(byte[] bytes) {
        StringBuilder builder = new StringBuilder();
        for (byte value : bytes) {
            if (builder.length() > 0) builder.append(' ');
            builder.append(String.format("%02X", value & 0xFF));
        }
        return builder.toString();
    }

    private static JsonObject body(HttpExchange exchange) throws Failure {
        try {
            String text = new String(exchange.getRequestBody().readAllBytes(), StandardCharsets.UTF_8);
            if (text.isBlank()) return new JsonObject();
            JsonElement element = JsonParser.parseString(text);
            if (!element.isJsonObject()) throw new Failure(400, "the body is not a JSON object");
            return element.getAsJsonObject();
        } catch (Failure failure) {
            throw failure;
        } catch (Exception error) {
            throw new Failure(400, "the body is not JSON: " + error.getMessage());
        }
    }

    private static String required(JsonObject body, String name) throws Failure {
        String value = string(body, name, null);
        if (value == null || value.isEmpty()) throw new Failure(400, name + " is required");
        return value;
    }

    private static String string(JsonObject body, String name, String fallback) {
        JsonElement value = body.get(name);
        return value == null || value.isJsonNull() ? fallback : value.getAsString();
    }

    private static int integer(JsonObject body, String name, int fallback) throws Failure {
        JsonElement value = body.get(name);
        if (value == null || value.isJsonNull()) return fallback;
        try {
            return value.getAsInt();
        } catch (Exception error) {
            throw new Failure(400, name + " is not a number");
        }
    }

    private static int integer(Map<String, String> query, String name, int fallback) throws Failure {
        String value = query.get(name);
        if (value == null) return fallback;
        try {
            return Math.max(0, Integer.parseInt(value));
        } catch (NumberFormatException error) {
            throw new Failure(400, name + " is not a number");
        }
    }

    private static Map<String, String> query(String raw) {
        Map<String, String> map = new HashMap<>();
        if (raw == null || raw.isEmpty()) return map;
        for (String pair : raw.split("&")) {
            String[] parts = pair.split("=", 2);
            map.put(URLDecoder.decode(parts[0], StandardCharsets.UTF_8),
                    parts.length > 1 ? URLDecoder.decode(parts[1], StandardCharsets.UTF_8) : "");
        }
        return map;
    }

    private void json(HttpExchange exchange, int status, JsonObject answer) throws Exception {
        byte[] bytes = (gson.toJson(answer) + "\n").getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().set("Content-Type", "application/json");
        exchange.sendResponseHeaders(status, bytes.length);
        try (OutputStream body = exchange.getResponseBody()) { body.write(bytes); }
    }

    private void error(HttpExchange exchange, int status, String message) {
        try {
            JsonObject answer = new JsonObject();
            answer.addProperty("error", message);
            json(exchange, status, answer);
        } catch (Exception ignored) {
            exchange.close();
        }
    }
}
