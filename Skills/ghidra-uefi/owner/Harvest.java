// The review document (Design/GHIDRA_SHARED_PLAN.md §9.1): the decisions a
// person or an agent made in a program, harvested from it at every publish.
//
// Only what the review made. Ghidra's source types do not say that alone: the
// PE loader writes comments, ApplyUefi types parameters as USER_DEFINED. So
// the owner records the program's decisions once, before the first change —
// the *baseline* (`baseline`) — and a harvest is what the program holds now
// minus what it held then: function names, signatures, parameters and locals
// whose source is USER_DEFINED, listing comments, user-named data and labels,
// and the types POST /v1/type added, as their C. No code, no bytes.
//
// Deterministic: every collection is keyed or sorted by address, keys are
// written in order, there is no time inside, so an unchanged review harvests
// to the same bytes and the same SHA-256.

import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonNull;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import ghidra.framework.Application;
import ghidra.framework.options.Options;
import ghidra.program.model.address.Address;
import ghidra.program.model.address.AddressIterator;
import ghidra.program.model.listing.CommentType;
import ghidra.program.model.listing.Data;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Listing;
import ghidra.program.model.listing.Parameter;
import ghidra.program.model.listing.Program;
import ghidra.program.model.listing.Variable;
import ghidra.program.model.symbol.SourceType;
import ghidra.program.model.symbol.Symbol;
import ghidra.program.model.symbol.SymbolIterator;
import ghidra.program.model.symbol.SymbolType;
import ghidra.program.model.util.StringPropertyMap;

import java.nio.charset.StandardCharsets;
import java.util.Map;
import java.util.TreeMap;

final class Harvest {
    static final String REASON = "ByteRipper.nameReason";
    static final String BY = "ByteRipper.nameBy";
    static final String OPTIONS = "ByteRipper";
    static final String TYPES = "reviewTypes";

    private Harvest() {}

    /** The document as bytes, and whether it holds any decision at all. */
    static final class Document {
        final byte[] bytes;
        final boolean reviewed;
        Document(byte[] bytes, boolean reviewed) { this.bytes = bytes; this.reviewed = reviewed; }
    }

    static final String BASELINE = "baseline";

    /** Records the baseline once; a program that has one keeps it. */
    static boolean recordBaseline(Program program) {
        Options options = program.getOptions(OPTIONS);
        if (options.getString(BASELINE, null) != null) return false;
        options.setString(BASELINE, decisions(program).toString());
        return true;
    }

    static Document of(Program program, String moduleSha, String projectId) {
        JsonObject now = decisions(program);
        String text = program.getOptions(OPTIONS).getString(BASELINE, null);
        if (text != null) subtract(now, JsonParser.parseString(text).getAsJsonObject());
        JsonObject functions = now.getAsJsonObject("functions");
        JsonArray comments = now.getAsJsonArray("comments");
        JsonObject data = now.getAsJsonObject("data");
        JsonArray types = now.getAsJsonArray("types");
        boolean reviewed = functions.size() > 0 || comments.size() > 0 || data.size() > 0 || types.size() > 0;
        JsonObject document = new JsonObject();
        document.add("comments", comments);
        document.add("data", data);
        document.add("functions", functions);
        JsonObject made = new JsonObject();
        made.addProperty("ghidra", Application.getApplicationVersion());
        document.add("made_with", made);
        JsonObject module = new JsonObject();
        module.addProperty("image_base", hex(program.getImageBase()));
        module.addProperty("language", program.getLanguageID().toString());
        module.addProperty("program", program.getName());
        module.addProperty("sha256", moduleSha);
        document.add("module", module);
        document.addProperty("project", projectId);
        document.addProperty("schema", 1);
        document.add("types", types);
        Gson gson = new GsonBuilder().disableHtmlEscaping().setPrettyPrinting().serializeNulls().create();
        return new Document((gson.toJson(document) + "\n").getBytes(StandardCharsets.UTF_8), reviewed);
    }

    /**
     * Removes from `now` whatever `baseline` already held: a field of a
     * function that has not changed, a parameter, local, comment or datum
     * equal to the one there was. A changed one stays whole.
     */
    private static void subtract(JsonObject now, JsonObject baseline) {
        JsonObject functions = now.getAsJsonObject("functions");
        JsonObject before = baseline.getAsJsonObject("functions");
        for (String entry : new java.util.ArrayList<>(functions.keySet())) {
            JsonObject function = functions.getAsJsonObject(entry);
            JsonObject old = before.has(entry) ? before.getAsJsonObject(entry) : new JsonObject();
            for (String field : new java.util.ArrayList<>(function.keySet())) {
                JsonElement value = function.get(field);
                if (value.isJsonArray() && old.has(field) && old.get(field).isJsonArray()) {
                    JsonArray kept = new JsonArray();
                    for (JsonElement item : value.getAsJsonArray()) {
                        if (!old.getAsJsonArray(field).contains(item)) kept.add(item);
                    }
                    if (kept.size() == 0) function.remove(field); else function.add(field, kept);
                } else if (value.equals(old.get(field))) {
                    function.remove(field);
                }
            }
            // A name kept from before takes its reason and author with it.
            if (!function.has("name")) { function.remove("by"); function.remove("reason"); }
            if (function.size() == 0) functions.remove(entry);
        }
        JsonArray comments = new JsonArray();
        for (JsonElement comment : now.getAsJsonArray("comments")) {
            if (!baseline.getAsJsonArray("comments").contains(comment)) comments.add(comment);
        }
        now.add("comments", comments);
        JsonObject data = now.getAsJsonObject("data");
        JsonObject oldData = baseline.getAsJsonObject("data");
        for (String address : new java.util.ArrayList<>(data.keySet())) {
            if (data.get(address).equals(oldData.get(address))) data.remove(address);
        }
    }

    /** Every decision the program holds, from whoever made it. */
    private static JsonObject decisions(Program program) {
        StringPropertyMap reasons = program.getUsrPropertyManager().getStringPropertyMap(REASON);
        StringPropertyMap by = program.getUsrPropertyManager().getStringPropertyMap(BY);

        TreeMap<Long, JsonObject> functions = new TreeMap<>();
        for (Function function : program.getFunctionManager().getFunctions(true)) {
            JsonObject entry = new JsonObject();
            Address at = function.getEntryPoint();
            if (function.getSymbol().getSource() == SourceType.USER_DEFINED) {
                entry.addProperty("name", function.getName());
                put(entry, "by", by == null ? null : by.getString(at));
                put(entry, "reason", reasons == null ? null : reasons.getString(at));
            }
            if (function.getSignatureSource() == SourceType.USER_DEFINED) {
                entry.addProperty("signature", function.getPrototypeString(false, false));
            }
            JsonArray params = new JsonArray();
            for (Parameter parameter : function.getParameters()) {
                if (parameter.getSource() != SourceType.USER_DEFINED) continue;
                JsonObject item = new JsonObject();
                item.addProperty("name", parameter.getName());
                item.addProperty("ordinal", parameter.getOrdinal());
                item.addProperty("storage", parameter.getVariableStorage().toString());
                item.addProperty("type", parameter.getDataType().getDisplayName());
                params.add(item);
            }
            if (params.size() > 0) entry.add("params", params);
            TreeMap<String, JsonObject> locals = new TreeMap<>();
            for (Variable local : function.getLocalVariables()) {
                if (local.getSource() != SourceType.USER_DEFINED) continue;
                JsonObject item = new JsonObject();
                String storage = local.getVariableStorage().toString();
                Address first = local.getFirstUseOffset() == 0 ? null : at.add(local.getFirstUseOffset());
                put(item, "first_use", first == null ? null : hex(first));
                item.addProperty("name", local.getName());
                item.addProperty("storage", storage);
                item.addProperty("type", local.getDataType().getDisplayName());
                locals.put(storage + "@" + (first == null ? "" : hex(first)), item);
            }
            if (!locals.isEmpty()) {
                JsonArray list = new JsonArray();
                locals.values().forEach(list::add);
                entry.add("locals", list);
            }
            if (entry.size() > 0) functions.put(at.getOffset(), sorted(entry));
        }

        // Comments of every kind, in address order, then kind order.
        JsonArray comments = new JsonArray();
        Listing listing = program.getListing();
        TreeMap<String, JsonObject> byPlace = new TreeMap<>();
        for (CommentType type : CommentType.values()) {
            AddressIterator addresses = listing.getCommentAddressIterator(type, program.getMemory(), true);
            while (addresses.hasNext()) {
                Address address = addresses.next();
                String text = listing.getComment(type, address);
                if (text == null) continue;
                JsonObject item = new JsonObject();
                item.addProperty("address", hex(address));
                item.addProperty("kind", type.name().toLowerCase());
                item.addProperty("text", text);
                byPlace.put(String.format("%016X/%s", address.getOffset(), type.name()), item);
            }
        }
        byPlace.values().forEach(comments::add);

        // User-named places that are not functions: data and labels.
        TreeMap<Long, JsonObject> data = new TreeMap<>();
        SymbolIterator symbols = program.getSymbolTable().getPrimarySymbolIterator(true);
        while (symbols.hasNext()) {
            Symbol symbol = symbols.next();
            if (symbol.getSource() != SourceType.USER_DEFINED || symbol.getSymbolType() != SymbolType.LABEL
                || !symbol.getAddress().isMemoryAddress()) continue;
            JsonObject item = new JsonObject();
            item.addProperty("name", symbol.getName());
            Data datum = listing.getDefinedDataAt(symbol.getAddress());
            if (datum != null) item.addProperty("type", datum.getDataType().getDisplayName());
            data.put(symbol.getAddress().getOffset(), item);
        }

        JsonArray types = new JsonArray();
        for (Map.Entry<String, String> type : reviewTypes(program).entrySet()) {
            JsonObject item = new JsonObject();
            item.addProperty("c", type.getValue());
            item.addProperty("name", type.getKey());
            types.add(item);
        }

        JsonObject all = new JsonObject();
        all.add("comments", comments);
        all.add("data", keyed(data));
        all.add("functions", keyed(functions));
        all.add("types", types);
        return all;
    }

    /** The C of every type a review added, by name. */
    static TreeMap<String, String> reviewTypes(Program program) {
        TreeMap<String, String> types = new TreeMap<>();
        Options options = program.getOptions(OPTIONS);
        String text = options.getString(TYPES, null);
        if (text == null || text.isEmpty()) return types;
        JsonObject stored = JsonParser.parseString(text).getAsJsonObject();
        for (String name : stored.keySet()) types.put(name, stored.get(name).getAsString());
        return types;
    }

    static void recordType(Program program, String name, String c) {
        TreeMap<String, String> types = reviewTypes(program);
        types.put(name, c);
        JsonObject stored = new JsonObject();
        types.forEach(stored::addProperty);
        program.getOptions(OPTIONS).setString(TYPES, stored.toString());
    }

    private static JsonObject keyed(TreeMap<Long, JsonObject> map) {
        JsonObject object = new JsonObject();
        map.forEach((offset, value) -> object.add(String.format("0x%X", offset), value));
        return object;
    }

    private static JsonObject sorted(JsonObject object) {
        JsonObject result = new JsonObject();
        new TreeMap<String, JsonElement>(object.asMap()).forEach(result::add);
        return result;
    }

    private static void put(JsonObject object, String key, String value) {
        if (value != null) object.addProperty(key, value);
    }

    static String hex(Address address) {
        return "0x" + Long.toHexString(address.getOffset()).toUpperCase();
    }
}
