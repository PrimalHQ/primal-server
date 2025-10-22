# TODO support functions with multiple methods

"""
get_changed_code() - Returns a Dict{String,String} where keys are Julia module names
and values are the code of changed functions or global variables.

This function runs `git status` to get the changed files,
then uses Meta.parse to identify only changed parts of the code.
"""
function get_changed_code(; directory=pwd(), target_server=nothing)
    function ex(cmd; server=nothing)
        cmd = "cd $directory && $cmd"
        cmd = isnothing(server) ? Cmd(["sh", "-c", cmd]) : Cmd(["ssh", "ppr$server", cmd])
        read(cmd, String)
    end

    # Initialize result dictionary
    changed_code = Dict{String,Vector{Expr}}()
    
    # Get list of modified and added .jl files using git status
    status_output = ex("git status --porcelain --ignore-submodules=all")
    lines = split(status_output, "\n")
    
    # Filter for modified and added Julia and SQL files
    changed_files = String[]
    for line in lines
        if !isempty(line) && ((line[2] == 'M') || startswith(line, "A")) && (endswith(line, ".jl") || endswith(line, ".sql"))
            # Extract filename from git status output
            m = match(r" ([^ ]+)$", line)
            file = m[1]
            push!(changed_files, file)
        end
    end
    
    function is_module_file(content::String)
        # Check if the file starts with a module declaration
        startswith(content, "module ") || startswith(content, "#module")
    end

    # Process each changed file
    for file in changed_files
        try
            changes = []
            if endswith(file, ".jl")
                # Process Julia files
                # Read the full content of the file
                new_content = read(joinpath(directory, file), String)
                is_module_file(new_content) || continue
                new_content, new_mod_name = process_module_content(new_content)
                
                # Read the full content of the staged or unchanged file 
                old_content = ex("git show :$file"; server=target_server)
                is_module_file(old_content) || continue
                old_content, old_mod_name = process_module_content(old_content)

                @assert old_mod_name == new_mod_name (old_mod_name, new_mod_name)

                mod_name = old_mod_name
                
                # Get only changed functions and global variables
                append!(changes, get_changed_functions_and_globals(file, new_content, old_content))
            elseif endswith(file, ".sql")
                # Process SQL files
                new_content = read(joinpath(directory, file), String)
                old_content = ex("git show :$file"; server=target_server)
                
                # Use filename as module name for SQL files
                mod_name = basename(file)
                
                # Get changed SQL elements
                append!(changes, get_changed_sql_elements(file, new_content, old_content))
            end
            if !isempty(changes)
                if !haskey(changed_code, mod_name)
                    changed_code[mod_name] = []
                end
                append!(changed_code[mod_name], changes)
            end
        catch e
            # Handle any errors reading files
            @warn "Error processing file $file: $e"
            rethrow()
        end
    end
    
    return changed_code
end

"""
get_changed_functions_and_globals(filename::String, new_content::String, old_content::String) - Extracts only the code for changed functions and global variables.
"""
function get_changed_functions_and_globals(filename::String, new_content::String, old_content::String)
    # Parse both versions
    old_parsed = Meta.parse(old_content; filename)
    new_parsed = Meta.parse(new_content; filename)

    # Compare ASTs to find changed functions and global variables
    return extract_changed_parts(old_parsed, new_parsed)
end

"""
extract_changed_parts(old_ast::Expr, new_ast::Expr) - Extracts only changed functions and global variables from AST comparison.
"""
function extract_changed_parts(old_ast::Expr, new_ast::Expr)
    # Find all function definitions in the new AST
    new_functions = find_function_definitions(new_ast)
    old_functions = find_function_definitions(old_ast)

    # Find global variable assignments in the new AST
    new_globals = find_global_assignments(new_ast)
    old_globals = find_global_assignments(old_ast)
    
    # Identify changed functions and globals
    changed_functions = Set{String}()
    changed_globals = Set{String}()
    
    # Check for changed functions
    for (name, new_def) in new_functions
        if haskey(old_functions, name)
            old_def = old_functions[name]
            if !functions_equal(old_def, new_def)
                push!(changed_functions, name)
            end
        else
            # New function
            push!(changed_functions, name)
        end
    end

    # Check for changed global variables
    for (name, new_def) in new_globals
        if haskey(old_globals, name)
            # old_def = old_globals[name]
            # if !assignments_equal(old_def, new_def)
            #     push!(changed_globals, name)
            # end
        else
            # New global variable
            push!(changed_globals, name)
        end
    end
    
    @show changed_functions
    @show changed_globals

    # Extract the actual code for changed parts
    changed_code = Expr[]
    
    # Extract changed functions
    for func_name in changed_functions
        if haskey(new_functions, func_name)
            func_def = new_functions[func_name]
            push!(changed_code, func_def)
        end
    end
    
    # Extract changed global variables
    for global_name in changed_globals
        if haskey(new_globals, global_name)
            global_def = new_globals[global_name]
            push!(changed_code, global_def)
        end
    end
    
    return changed_code
end

"""
find_function_definitions(ast::Expr) - Finds all function definitions in an AST.
"""
function find_function_definitions(ast::Expr)
    functions = Dict{String, Expr}()
    
    # Recursively search for function definitions
    function search_for_functions(expr::Expr)
        if expr.head == :function
            # Function definition: :function => [name, body]
            name = expr.args[1]
            if isa(name, Expr) && name.head == :call
                # For function calls like f(x) or f(x, y)
                name = name.args[1]  # Get the function name
            end
            functions[string(name)] = expr
        elseif expr.head == :macrocall && try expr.args[3].head == :function && expr.args[3].args[1].head == :call catch _ false end
            name = expr.args[3].args[1].args[1]
            functions[string(name)] = expr
        # elseif expr.head == :macro
        #     # Macros are also functions in a way
        #     name = expr.args[1]
        #     if isa(name, Expr) && name.head == :call
        #         name = name.args[1]
        #     end
        #     functions[string(name)] = expr
        else
            # Recursively search in sub-expressions
            for arg in expr.args
                if isa(arg, Expr)
                    search_for_functions(arg)
                end
            end
        end
    end
    
    search_for_functions(ast)
    return functions
end

"""
find_global_assignments(ast::Expr) - Finds all global variable assignments in an AST.
"""
function find_global_assignments(ast::Expr)
    assignments = Dict{String, Expr}()
    
    for expr in ast.args[3].args
        if expr isa Expr && expr.head == :(=) && length(expr.args) >= 2
            # Assignment expression: a = b
            lhs = expr.args[1]
            if isa(lhs, Symbol)
                assignments[string(lhs)] = expr
            end
        end
    end

    return assignments
end

"""
functions_equal(old_func::Expr, new_func::Expr) - Compares two function definitions for equality.
"""
function functions_equal(old_func::Expr, new_func::Expr)
    old_func = remove_linenums(old_func)
    new_func = remove_linenums(new_func)
    # For simplicity, we'll compare the string representations
    # In a more sophisticated implementation, you might want to do a deeper AST comparison
    return string(old_func) == string(new_func)
end

"""
assignments_equal(old_assign::Expr, new_assign::Expr) - Compares two assignment expressions for equality.
"""
function assignments_equal(old_assign::Expr, new_assign::Expr)
    # For simplicity, we'll compare the string representations
    return string(old_assign) == string(new_assign)
end

function process_module_content(content::String)
    lines = split(content, "\n")
    first_line = strip(lines[1])
    mod_name = split(first_line)[2]

    (startswith(content, "#module") ? string(content[2:end]) * "\nend\n" : content, mod_name)
end

function remove_linenums(expr::Expr)
    args = []
    for arg in expr.args
        if arg isa LineNumberNode
            push!(args, LineNumberNode(0, nothing))
        elseif arg isa Expr
            push!(args, remove_linenums(arg))
        else
            push!(args, arg)
        end
    end
    Expr(expr.head, args...)
end

"""
get_changed_sql_elements(filename::String, new_content::String, old_content::String) - Extracts changed SQL functions, types, and procedures.
"""
function get_changed_sql_elements(filename::String, new_content::String, old_content::String)
    # Parse SQL content to extract functions, types, procedures
    new_elements = parse_sql_elements(new_content)
    old_elements = parse_sql_elements(old_content)
    
    # Find changed elements
    changed_elements = String[]
    
    for (name, element) in new_elements
        if haskey(old_elements, name)
            # Compare existing elements
            if normalize_sql(element) != normalize_sql(old_elements[name])
                push!(changed_elements, element)
            end
        else
            # New element
            push!(changed_elements, element)
        end
    end
    
    @show length(changed_elements), "SQL elements changed"
    
    return changed_elements
end

"""
parse_sql_elements(content::String) - Parses SQL content to extract functions, types, and procedures.
"""
function parse_sql_elements(content::String)
    elements = Dict{String, String}()
    
    # Split by semicolons but be careful with strings and function bodies
    statements = split_sql_statements(content)
    
    for statement in statements
        statement = strip(statement)
        if isempty(statement)
            continue
        end
        
        # Match different SQL elements with case-insensitive matching
        if occursin(r"CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION"i, statement)
            # Extract function name
            m = match(r"CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+(?:public\.)?([a-zA-Z_][a-zA-Z0-9_]*)"i, statement)
            if m !== nothing
                name = m.captures[1]
                elements[name] = statement
            end
        elseif occursin(r"CREATE\s+(?:OR\s+REPLACE\s+)?PROCEDURE"i, statement)
            # Extract procedure name
            m = match(r"CREATE\s+(?:OR\s+REPLACE\s+)?PROCEDURE\s+(?:public\.)?([a-zA-Z_][a-zA-Z0-9_]*)"i, statement)
            if m !== nothing
                name = m.captures[1]
                elements[name] = statement
            end
        elseif occursin(r"CREATE\s+TYPE"i, statement)
            # Extract type name
            m = match(r"CREATE\s+TYPE\s+([a-zA-Z_][a-zA-Z0-9_]*)"i, statement)
            if m !== nothing
                name = m.captures[1]
                elements[name] = statement
            end
        end
    end
    
    return elements
end

"""
split_sql_statements(content::String) - Split SQL content into individual statements, handling dollar-quoted strings.
"""
function split_sql_statements(content::String)
    statements = String[]
    current_statement = ""
    in_dollar_quote = false
    dollar_tag = ""
    i = 1
    
    while i <= length(content)
        char = content[i]
        
        if char == '$' && !in_dollar_quote
            # Look for dollar-quoted string start
            tag_match = match(r"^\$([^$]*)\$", content[i:end])
            if tag_match !== nothing
                dollar_tag = tag_match.captures[1]
                in_dollar_quote = true
                tag_len = length(tag_match.match)
                current_statement *= content[i:i+tag_len-1]
                i += tag_len
                continue
            end
        elseif char == '$' && in_dollar_quote
            # Look for matching dollar-quoted string end
            end_tag = "\$" * dollar_tag * "\$"
            if startswith(content[i:end], end_tag)
                in_dollar_quote = false
                current_statement *= end_tag
                i += length(end_tag)
                continue
            end
        elseif char == ';' && !in_dollar_quote
            # End of statement
            current_statement *= char
            push!(statements, current_statement)
            current_statement = ""
            i += 1
            continue
        end
        
        current_statement *= char
        i += 1
    end
    
    # Add final statement if not empty
    if !isempty(strip(current_statement))
        push!(statements, current_statement)
    end
    
    return statements
end

"""
normalize_sql(sql::String) - Normalizes SQL text for comparison by removing extra whitespace and comments.
"""
function normalize_sql(sql::String)
    # Remove SQL comments (-- style)
    sql = replace(sql, r"--.*$"m => "")
    # Remove /* */ style comments
    sql = replace(sql, r"/\*.*?\*/"s => "")
    # Normalize whitespace
    sql = replace(sql, r"\s+" => " ")
    # Trim
    return strip(sql)
end

function load_changed_code(; directory=pwd(), target_server=nothing, target_node=17, dry_run=false)
    for (mod, changes) in get_changed_code(; directory, target_server)
        if endswith(mod, ".sql")
            # Handle SQL files differently - just print the changes
            if dry_run || true  # Always dry-run for SQL for now
                println("================================")
                println("SQL FILE: $mod")
                for element in changes
                    println(element)
                    println("===============")
                end
                println()
            end
        else
            # Handle Julia modules
            mod = Symbol(mod)
            if dry_run
                println("================================")
                println("MODULE: $mod")
                for expr in changes
                    println(expr)
                    println("===============")
                end
                println()
            else
                for expr in changes
                    if isnothing(target_server)
                        getproperty(Main, mod).eval(expr)
                    else
                        rex(target_server, target_node, :(Main.$mod.eval($(QuoteNode(expr)))))
                    end
                end
                println("$mod: $(length(changes)) changes loaded")
            end
        end
    end
end

