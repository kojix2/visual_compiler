require "json"
require "kemal"
require "compiler/crystal/syntax"
require "set"
require "base64"

module VisualCompiler
  VERSION                 = "0.1.0"
  MAX_INPUT_BYTES         = 1_000_000
  REQUEST_TIMEOUT_SECONDS =       120
  DEFAULT_TRACE_PRELUDE   = "nano"

  record Snapshot,
    id : String,
    label : String,
    elapsed_ms : Int64,
    node_count : Int32,
    ast_text : String,
    tree_lines : Array(String),
    metadata : Hash(String, String),
    diff_lines : Array(String)

  class RequestTooLarge < Exception
  end

  class RequestTimeout < Exception
  end

  class ChildCollector < Crystal::Visitor
    getter nodes

    def initialize
      @nodes = [] of Crystal::ASTNode
    end

    def visit(node : Crystal::ASTNode)
      @nodes << node
      false
    end
  end

  extend self

  def run
    Kemal.config.serve_static = false

    get "/" do
      render "src/views/index.ecr"
    end

    post "/api/trace" do |env|
      source = read_source(env)
      prelude = read_prelude(env)
      no_debug = read_no_debug(env)
      env.response.content_type = "application/json"
      if env.response.status_code == 413
        next error_response(RequestTooLarge.new("payload too large"), "", [] of Snapshot, "", nil, nil, prelude)
      end

      begin
        with_timeout(REQUEST_TIMEOUT_SECONDS) do
          snapshots, llvm_ir, compile_log, program_metadata, semantic_summary = trace(source, prelude, no_debug)
          build_trace_response(source, snapshots, llvm_ir, compile_log, program_metadata, semantic_summary, prelude)
        end
      rescue ex : RequestTimeout
        env.response.status_code = 408
        error_response(ex, source, [] of Snapshot, "", nil, nil, prelude)
      rescue ex
        env.response.status_code = 400
        error_response(ex, source, [] of Snapshot, "", nil, nil, prelude)
      end
    end

    Kemal.run
  end

  def trace(source : String, prelude : String, no_debug : Bool = false)
    snapshots = [] of Snapshot

    canonical_started = Time.instant
    parsed = Crystal::Parser.parse(source)
    canonical_source = String.build { |io| parsed.to_s(io) }
    canonical_ast = Crystal::Parser.parse(canonical_source)
    canonical_elapsed = elapsed_ms(canonical_started)
    canonical_lines, canonical_count = flatten_tree(canonical_ast)
    canonical_text = String.build { |io| canonical_ast.to_s(io) }
    snapshots << Snapshot.new(
      id: "canonical",
      label: "Canonical Parse",
      elapsed_ms: canonical_elapsed,
      node_count: canonical_count,
      ast_text: canonical_text,
      tree_lines: canonical_lines,
      metadata: {
        "stage"   => "Parser",
        "summary" => "入力を正規化した構文木",
      },
      diff_lines: [] of String
    )

    semantic_started = Time.instant
    program_metadata = extract_program_metadata(source, prelude, no_debug)
    semantic_elapsed = elapsed_ms(semantic_started)
    semantic_counts = metadata_counts(program_metadata)
    snapshots << Snapshot.new(
      id: "semantic",
      label: "Semantic Summary",
      elapsed_ms: semantic_elapsed,
      node_count: canonical_count,
      ast_text: canonical_text,
      tree_lines: canonical_lines,
      metadata: {
        "stage"   => "Semantic",
        "summary" => "Programと型情報の蓄積結果サマリ",
        "prelude" => prelude,
      },
      diff_lines: diff_count_lines({} of String => Int64, semantic_counts)
    )

    llvm_started = Time.instant
    llvm_ir, compile_log = compile_llvm_ir(source, prelude, no_debug)
    llvm_elapsed = elapsed_ms(llvm_started)
    snapshots << Snapshot.new(
      id: "codegen",
      label: "Codegen (LLVM IR)",
      elapsed_ms: llvm_elapsed,
      node_count: canonical_count,
      ast_text: canonical_text,
      tree_lines: canonical_lines,
      metadata: {
        "stage"      => "Codegen",
        "summary"    => "crystal build --emit llvm-ir の結果",
        "llvm_lines" => llvm_ir.lines.size.to_s,
        "prelude"    => prelude,
      },
      diff_lines: diff_count_lines(semantic_counts, semantic_counts)
    )

    semantic_summary = build_semantic_summary(program_metadata)

    {snapshots, llvm_ir, compile_log, program_metadata, semantic_summary}
  end

  def metadata_counts(program_metadata : Hash(String, JSON::Any)?)
    result = {} of String => Int64
    return result unless program_metadata

    program_metadata.each do |key, value|
      next unless key.ends_with?("_count")
      int_value = value.as_i64?
      next unless int_value
      result[key] = int_value
    end
    result
  end

  def diff_count_lines(before : Hash(String, Int64), after : Hash(String, Int64))
    keys = (before.keys + after.keys).uniq.sort
    diff = [] of String
    keys.each do |key|
      old_value = before[key]? || 0_i64
      new_value = after[key]? || 0_i64
      delta = new_value - old_value
      next if delta == 0
      sign = delta > 0 ? "+" : "-"
      diff << "#{sign} #{key}: #{old_value} -> #{new_value} (#{delta >= 0 ? "+" : ""}#{delta})"
    end
    diff
  end

  def build_semantic_summary(program_metadata : Hash(String, JSON::Any)?) : Hash(String, JSON::Any)?
    return nil unless program_metadata

    summary = {} of String => JSON::Any
    %w(types_count symbols_count unions_count vars_count const_initializers_count class_var_initializers_count file_modules_count requires_count prelude).each do |key|
      value = program_metadata[key]?
      summary[key] = value if value
    end
    summary["focus"] = JSON::Any.new("MetaVars and Program accumulation")
    summary
  end

  def extract_program_metadata(source : String, prelude : String, no_debug : Bool = false) : Hash(String, JSON::Any)?
    crystal_path = ENV["CRYSTAL_PATH"]? || default_crystal_path
    source_b64 = Base64.strict_encode(source)

    script = <<-'CR'
      require "json"
      require "base64"
      require "compiler/requires"

      source = Base64.decode_string(ENV.fetch("VC_SOURCE_B64"))
      compiler = Crystal::Compiler.new
      compiler.prelude = ENV["VC_TRACE_PRELUDE"]? || "prelude"
      if ENV["VC_NO_DEBUG"]? == "1"
        compiler.debug = Crystal::Debug::None
      end
      source_file = Crystal::Compiler::Source.new("input.cr", source)
      result = compiler.top_level_semantic(source_file)
      program = result.program

      metadata = {
        "types_count" => program.types.size,
        "symbols_count" => program.symbols.size,
        "unions_count" => program.unions.size,
        "vars_count" => program.vars.size,
        "const_initializers_count" => program.const_initializers.size,
        "class_var_initializers_count" => program.class_var_initializers.size,
        "file_modules_count" => program.file_modules.size,
        "requires_count" => program.requires.size,
        "sample_types" => program.types.keys.map(&.to_s).sort.first(80),
        "sample_symbols" => program.symbols.to_a.map(&.to_s).sort.first(80),
        "sample_requires" => program.requires.to_a.map(&.to_s).sort.first(80),
        "prelude" => compiler.prelude,
      }

      puts metadata.to_json
    CR

    stdout = IO::Memory.new
    stderr = IO::Memory.new

    env = {
      "CRYSTAL_PATH"     => crystal_path,
      "VC_SOURCE_B64"    => source_b64,
      "VC_TRACE_PRELUDE" => prelude,
    }
    env["VC_NO_DEBUG"] = "1" if no_debug

    status = Process.run(
      "crystal",
      ["eval", "-Di_know_what_im_doing", "-Dwithout_libxml2", script],
      env: env,
      output: stdout,
      error: stderr
    )

    return nil unless status.success?

    parsed = JSON.parse(stdout.to_s)
    parsed.as_h?
  rescue
    nil
  end

  def default_crystal_path : String
    stdout = IO::Memory.new
    stderr = IO::Memory.new
    status = Process.run("crystal", ["env", "CRYSTAL_PATH"], output: stdout, error: stderr)
    path = stdout.to_s.strip
    return path unless path.empty?
    return "lib" unless status.success?
    "lib"
  rescue
    "lib"
  end

  def compile_llvm_ir(source : String, prelude : String, no_debug : Bool = false)
    token = Random::Secure.hex(8)
    source_path = "/tmp/visual_compiler_#{token}.cr"
    binary_path = "/tmp/visual_compiler_#{token}.out"
    ll_primary = "#{binary_path}.ll"
    ll_secondary = source_path.sub(/\.cr$/, ".ll")

    stdout = IO::Memory.new
    stderr = IO::Memory.new
    begin
      File.write(source_path, source)
      build_args = ["build", source_path, "--prelude", prelude, "--emit", "llvm-ir", "-o", binary_path]
      build_args << "--no-debug" if no_debug
      status = Process.run(
        "crystal",
        build_args,
        output: stdout,
        error: stderr
      )

      compile_log = String.build do |io|
        io << stdout.to_s
        io << "\n" unless stdout.to_s.empty? || stderr.to_s.empty?
        io << stderr.to_s
      end

      raise "LLVM IR生成に失敗しました: #{compile_log}" unless status.success?

      llvm_ir = if File.exists?(ll_primary)
                  File.read(ll_primary)
                elsif File.exists?(ll_secondary)
                  File.read(ll_secondary)
                else
                  ""
                end

      raise "LLVM IRファイルが見つかりませんでした" if llvm_ir.empty?

      {llvm_ir, compile_log}
    ensure
      File.delete?(source_path)
      File.delete?(binary_path)
      File.delete?(ll_primary)
      File.delete?(ll_secondary)
    end
  end

  def build_trace_response(source : String, snapshots : Array(Snapshot), llvm_ir : String, compile_log : String, program_metadata : Hash(String, JSON::Any)?, semantic_summary : Hash(String, JSON::Any)?, prelude : String)
    JSON.build do |json|
      json.object do
        json.field "source", source
        json.field "prelude", prelude
        json.field "snapshots" do
          json.array do
            snapshots.each do |snapshot|
              json.object do
                json.field "id", snapshot.id
                json.field "label", snapshot.label
                json.field "elapsed_ms", snapshot.elapsed_ms
                json.field "node_count", snapshot.node_count
                json.field "ast_text", snapshot.ast_text
                json.field "tree" do
                  json.array do
                    snapshot.tree_lines.each { |line| json.string(line) }
                  end
                end
                json.field "metadata" do
                  json.object do
                    snapshot.metadata.each do |key, value|
                      json.field key, value
                    end
                  end
                end
                json.field "diff" do
                  json.array do
                    snapshot.diff_lines.each { |line| json.string(line) }
                  end
                end
              end
            end
          end
        end
        json.field "llvm_ir", llvm_ir
        json.field "compile_log", compile_log
        json.field "program_metadata" do
          if program_metadata
            JSON::Any.new(program_metadata).to_json(json)
          else
            json.null
          end
        end
        json.field "semantic_summary" do
          if semantic_summary
            JSON::Any.new(semantic_summary).to_json(json)
          else
            json.null
          end
        end
      end
    end
  end

  def read_source(env) : String
    if (length = env.request.content_length) && length > MAX_INPUT_BYTES
      env.response.status_code = 413
      return ""
    end

    body = env.request.body.try(&.gets_to_end) || ""
    if body.bytesize > MAX_INPUT_BYTES
      env.response.status_code = 413
      return ""
    end
    return body if body.empty?

    begin
      json = JSON.parse(body)
      code = json["code"]?
      return code.as_s if code && code.as_s?
    rescue
      # pass through and use plain body
    end

    body
  end

  def read_prelude(env) : String
    prelude = env.params.query["prelude"]?
    return DEFAULT_TRACE_PRELUDE if prelude.nil? || prelude.empty?
    prelude
  end

  def read_no_debug(env) : Bool
    no_debug = env.params.query["no_debug"]?
    return false if no_debug.nil? || no_debug.empty?
    no_debug == "1" || no_debug == "true"
  end

  def error_response(ex : Exception, source : String, snapshots : Array(Snapshot), llvm_ir : String, program_metadata : Hash(String, JSON::Any)?, semantic_summary : Hash(String, JSON::Any)?, prelude : String)
    message = ex.message || ex.class.name
    JSON.build do |json|
      json.object do
        json.field "source", source
        json.field "prelude", prelude
        json.field "snapshots" do
          json.array do
            snapshots.each do |snapshot|
              json.object do
                json.field "id", snapshot.id
              end
            end
          end
        end
        json.field "llvm_ir", llvm_ir
        json.field "compile_log", ""
        json.field "program_metadata" do
          if program_metadata
            JSON::Any.new(program_metadata).to_json(json)
          else
            json.null
          end
        end
        json.field "semantic_summary" do
          if semantic_summary
            JSON::Any.new(semantic_summary).to_json(json)
          else
            json.null
          end
        end
        json.field "errors" do
          json.array do
            json.object do
              json.field "message", message
              json.field "kind", ex.class.name
            end
          end
        end
      end
    end
  end

  def with_timeout(seconds : Int32, &block : -> String)
    result_channel = Channel(String).new(1)
    error_channel = Channel(Exception).new(1)
    operation = block

    spawn do
      begin
        result_channel.send(operation.call)
      rescue ex
        error_channel.send(ex)
      end
    end

    select
    when result = result_channel.receive
      result
    when ex = error_channel.receive
      raise ex
    when timeout(seconds.seconds)
      raise RequestTimeout.new("request timeout")
    end
  end

  def elapsed_ms(started : Time::Instant)
    ((Time.instant - started).total_milliseconds).to_i64
  end

  def flatten_tree(root : Crystal::ASTNode)
    lines = [] of String
    count = 0
    walk(root) do |node, depth|
      count += 1
      lines << "#{"  " * depth}#{node.class.name.split("::").last}#{node_label(node)}"
    end
    {lines, count.to_i32}
  end

  def walk(node : Crystal::ASTNode, depth = 0, &block : Crystal::ASTNode, Int32 ->)
    yield node, depth
    child_nodes(node).each do |child|
      walk(child, depth + 1, &block)
    end
  end

  def child_nodes(node : Crystal::ASTNode)
    collector = ChildCollector.new
    node.accept_children(collector)
    collector.nodes
  end

  def node_label(node : Crystal::ASTNode)
    case node
    when Crystal::Path
      "(#{node.names.join("::")})"
    when Crystal::Def
      "(#{node.name})"
    when Crystal::ClassDef
      "(#{node.name})"
    when Crystal::ModuleDef
      "(#{node.name})"
    when Crystal::Assign
      "(=)"
    when Crystal::Var
      "(#{node.name})"
    when Crystal::Call
      name = node.name
      "(#{name})"
    else
      ""
    end
  end

  def build_diff(before : Array(String), after : Array(String), limit = 120)
    before_set = before.to_set
    after_set = after.to_set
    added = after.reject { |line| before_set.includes?(line) }
    removed = before.reject { |line| after_set.includes?(line) }

    diff = [] of String
    added.first(limit).each { |line| diff << "+ #{line}" }
    removed.first(limit).each { |line| diff << "- #{line}" }
    diff
  end
end
