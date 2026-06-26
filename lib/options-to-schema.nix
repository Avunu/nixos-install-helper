# options-to-schema.nix
# ─────────────────────────────────────────────────────────────────────────────
# Derive a Draft-07 JSON Schema (as a Nix attrset ready for `builtins.toJSON`)
# from an evaluated NixOS `options` tree.
#
# The "configurable surface" of a consuming project is whatever options its
# install modules DECLARE — so the schema is read straight off the evaluated
# option tree, never hand-mirrored. A project that declares no options (e.g.
# server-little_cocalico, every value settled in-repo) yields an empty schema,
# which the gum layer treats as "no prompts, just install".
#
# Root selection:
#   • optionRoots != null  → take exactly those top-level attr names.
#   • optionRoots == null   → auto-detect: any top-level namespace that declares
#                             at least one option under `sourcePrefixes` (the
#                             consuming flake's own source). This excludes
#                             nixpkgs' own options and infrastructure namespaces
#                             pulled from inputs (disko.*, age.*), whose options
#                             are declared under THEIR store paths, not the
#                             project's.
#
# Within a selected root every visible, serializable option leaf is emitted;
# `internal`/`visible = false` options (router._internal) and non-serializable
# types (package, functionTo, …) are dropped — they keep their Nix-side defaults.
{
  lib,
  options,
  optionRoots ? null,
  sourcePrefixes ? [ ],
}:
let
  inherit (lib)
    isAttrs
    hasPrefix
    any
    elem
    foldlAttrs
    optionalAttrs
    ;

  isOption = x: isAttrs x && (x._type or null) == "option";

  visibleOpt = opt: (opt.internal or false) == false && (opt.visible or true) != false;

  declMatch =
    opt:
    let
      decls = map toString (opt.declarations or [ ]);
    in
    sourcePrefixes == [ ] || any (d: any (p: hasPrefix (toString p) d) sourcePrefixes) decls;

  # Bounded DFS: does this namespace subtree contain a leaf declared under the
  # project source? Used only for auto-detecting roots (depth keeps it cheap and
  # avoids descending recursive submodules like systemd.services).
  subtreeDeclaredHere =
    depth: node:
    if depth < 0 then
      false
    else if isOption node then
      declMatch node
    else if isAttrs node then
      any (v: subtreeDeclaredHere (depth - 1) v) (builtins.attrValues (removeInternalAttrs node))
    else
      false;

  # Drop module-system bookkeeping keys (_module, …) so we only walk real option
  # entries. Option leaves are detected via `isOption` BEFORE this is ever
  # applied, so a legitimately-named `type` sub-option is preserved.
  removeInternalAttrs = lib.filterAttrs (n: _: !(lib.hasPrefix "_" n));

  inList = x: xs: lib.elem x xs;

  # ── enum value extraction (nixpkgs version-tolerant) ───────────────────────
  enumValues =
    type:
    let
      p = type.functor.payload or null;
    in
    if p == null then
      [ ]
    else if lib.isList p then
      p
    else
      (p.values or [ ]);

  # ── type → schema fragment (null = skip / non-serializable) ────────────────
  typeToSchema =
    type:
    let
      name = type.name or "";
      nested = type.nestedTypes or { };
      elem = nested.elemType or (type.functor.wrapped or null);
    in
    if
      inList name [
        "str"
        "string"
        "path"
        "singleLineStr"
        "passwdEntry"
        "nonEmptyStr"
        "lines"
        "commas"
        "separatedString"
        "pathInStore"
      ]
      || builtins.match ".*[Ss]tr.*" name != null
    then
      { type = "string"; }
    else if name == "bool" then
      { type = "boolean"; }
    else if
      inList name [
        "port"
        "ints.u16"
        "unsignedInt16"
      ]
    then
      {
        type = "integer";
        minimum = 0;
        maximum = 65535;
      }
    else if
      inList name [
        "int"
        "signedInt"
        "unsignedInt"
        "positiveInt"
        "ints.positive"
        "ints.unsigned"
      ]
      || builtins.match ".*[Ii]nt.*" name != null
    then
      { type = "integer"; }
    else if name == "float" then
      { type = "number"; }
    else if name == "enum" then
      { enum = enumValues type; }
    else if name == "nullOr" then
      let
        inner = if elem != null then typeToSchema elem else null;
      in
      if inner == null then
        null
      else if inner ? type && builtins.isString inner.type then
        inner
        // {
          type = [
            inner.type
            "null"
          ];
        }
      else
        inner # enum / compound: leave as-is, null handled loosely
    else if
      inList name [
        "listOf"
        "nonEmptyListOf"
      ]
    then
      let
        items = if elem != null then typeToSchema elem else null;
      in
      # A list of a non-serializable element type (e.g. listOf package) is itself
      # non-serializable → drop the whole option.
      if items == null then
        null
      else
        {
          type = "array";
          items = items;
        }
    else if
      inList name [
        "attrsOf"
        "lazyAttrsOf"
      ]
    then
      let
        ap = if elem != null then typeToSchema elem else null;
      in
      if ap == null then
        null
      else
        {
          type = "object";
          additionalProperties = ap;
        }
    else if
      inList name [
        "submodule"
        "submoduleWith"
      ]
    then
      treeToSchema (type.getSubOptions [ ])
    else
      null; # package, functionTo, anything, either, oneOf, … → skip

  # ── recurse an options tree → object schema ────────────────────────────────
  treeToSchema =
    opts:
    let
      # Drop _module (and any other _-prefixed bookkeeping) at every level —
      # getSubOptions injects `_module.args` into each submodule's option set.
      acc =
        foldlAttrs
          (
            a: key: val:
            if isOption val then
              (
                if !visibleOpt val then
                  a
                else
                  let
                    s = typeToSchema (val.type or { });
                  in
                  if s == null then
                    a
                  else
                    let
                      withMeta =
                        s
                        // (
                          let
                            d = builtins.tryEval (val.default or null);
                          in
                          optionalAttrs (val ? default && d.success) { default = d.value; }
                        )
                        // optionalAttrs (val ? description) {
                          description =
                            if builtins.isString val.description then val.description else (val.description.text or "");
                        };
                    in
                    {
                      props = a.props // {
                        ${key} = withMeta;
                      };
                      required = a.required ++ (if (val ? default) then [ ] else [ key ]);
                    }
              )
            else if isAttrs val then
              let
                sub = treeToSchema val;
              in
              if (sub.properties or { }) == { } then
                a
              else
                {
                  inherit (a) required;
                  props = a.props // {
                    ${key} = sub;
                  };
                }
            else
              a
          )
          {
            props = { };
            required = [ ];
          }
          (removeInternalAttrs opts);
    in
    {
      type = "object";
      additionalProperties = false;
      properties = acc.props;
    }
    // optionalAttrs (acc.required != [ ]) { required = acc.required; };

  # ── root selection ─────────────────────────────────────────────────────────
  topLevel = removeInternalAttrs options;

  roots =
    if optionRoots != null then
      lib.filterAttrs (n: _: inList n optionRoots) topLevel
    else
      lib.filterAttrs (n: v: subtreeDeclaredHere 3 v) topLevel;

  schema = treeToSchema roots;
in
schema
// {
  "$schema" = "http://json-schema.org/draft-07/schema#";
}
