use proc_macro::TokenStream;
use quote::quote;
use syn::{parse_macro_input, FnArg, ItemFn, Pat, Token};
use syn::parse::{Parse, ParseStream};
use syn::punctuated::Punctuated;

#[derive(Default)]
struct ProcnodeArgs {
    module: Option<String>,
    func: Option<String>,
}

impl Parse for ProcnodeArgs {
    fn parse(input: ParseStream) -> syn::Result<Self> {
        let mut args = ProcnodeArgs::default();

        let parsed = Punctuated::<syn::Meta, Token![,]>::parse_terminated(input)?;

        for meta in parsed {
            if let syn::Meta::NameValue(nv) = meta {
                let ident = nv.path.get_ident().ok_or_else(|| {
                    syn::Error::new_spanned(&nv.path, "expected identifier")
                })?;

                if ident == "module" {
                    if let syn::Expr::Lit(expr_lit) = &nv.value {
                        if let syn::Lit::Str(lit_str) = &expr_lit.lit {
                            args.module = Some(lit_str.value());
                        }
                    }
                } else if ident == "func" {
                    if let syn::Expr::Lit(expr_lit) = &nv.value {
                        if let syn::Lit::Str(lit_str) = &expr_lit.lit {
                            args.func = Some(lit_str.value());
                        }
                    }
                }
            }
        }

        Ok(args)
    }
}

/// Attribute macro for processing nodes.
///
/// # Usage
///
/// Decorate a clean implementation function to generate handler and registration:
///
/// ```rust
/// #[procnode(module = "PrimalServer.Media", func = "media_variants_pn")]
/// pub async fn media_variants_pn(
///     state: &AppState,
///     url: &String,
///     variant_specs: Option<&Vec<(Size, Animated)>>
/// ) -> anyhow::Result<Value> {
///     // clean implementation
/// }
/// ```
///
/// This generates:
/// - `handler_media_variants_pn(state, id, args, kwargs)` - handler that parses args/kwargs
/// - `media_variants_pn_immediate(state, url, ...) -> (NodeId, Value)` - convenience wrapper
/// - `register_media_variants_pn()` - registration helper
/// - Renames original to `media_variants_pn_impl` for the clean implementation
#[proc_macro_attribute]
pub fn procnode(attr: TokenStream, item: TokenStream) -> TokenStream {
    let args = parse_macro_input!(attr as ProcnodeArgs);
    let input_fn = parse_macro_input!(item as ItemFn);

    let module_name = args.module.unwrap_or_else(|| "PrimalServer.Media".to_string());
    let impl_name = &input_fn.sig.ident;
    let impl_name_str = impl_name.to_string();

    // Extract base name (remove _pn suffix if present)
    let base_name = impl_name_str.strip_suffix("_pn").unwrap_or(&impl_name_str);

    let handler_name = syn::Ident::new(&format!("handler_{}_pn", base_name), impl_name.span());
    let register_name = syn::Ident::new(&format!("register_{}_pn", base_name), impl_name.span());

    // Use func override or derive from base_name
    let processing_func_name = args.func.unwrap_or_else(|| format!("{}_pn", base_name));

    // Extract function parameters (skip first param which should be state: &AppState)
    // Also detect if second param is id: &NodeId for logging
    let mut impl_params = Vec::new();
    let mut impl_param_names = Vec::new();
    let mut has_state = false;
    let mut arg_index = 0; // Track position in Julia tuple args (after est)

    for (idx, arg) in input_fn.sig.inputs.iter().enumerate() {
        if let FnArg::Typed(pat_type) = arg {
            if let Pat::Ident(pat_ident) = &*pat_type.pat {
                let param_name = &pat_ident.ident;
                let param_type = &pat_type.ty;

                if idx == 0 && param_name == "state" {
                    has_state = true;
                    continue;
                }

                if idx == 1 && param_name == "id" {
                    impl_params.push((param_name.clone(), param_type.clone(), None)); // None indicates it comes from handler, not args
                    impl_param_names.push(param_name.clone());
                    continue;
                }

                impl_params.push((param_name.clone(), param_type.clone(), Some(arg_index)));
                impl_param_names.push(param_name.clone());
                arg_index += 1;
            }
        }
    }

    if !has_state {
        return syn::Error::new_spanned(
            &input_fn.sig,
            "First parameter must be 'state: &AppState'"
        ).to_compile_error().into();
    }

    // Generate argument parsing code for handler
    // This parses from Julia-style Tuple args and NamedTuple kwargs
    let mut arg_parsers = Vec::new();
    for (param_name, param_type, idx_opt) in &impl_params {
        // Skip id parameter (idx == None), it comes from handler directly
        let idx = match idx_opt {
            Some(i) => *i,
            None => continue, // Skip id parameter
        };

        let param_name_str = param_name.to_string();
        let julia_idx = idx + 1; // +1 because args[0] is est/CacheStorage

        // Check if parameter is Option type
        let is_option = is_option_type(param_type);

        if is_option {
            // For Option types, try to parse but default to None if missing
            arg_parsers.push(quote! {
                let #param_name = if let serde_json::Value::Object(o) = &args {
                    if let Some(serde_json::Value::Array(v)) = o.get("_v") {
                        if v.len() > #julia_idx as usize {
                            parse_param(v.get(#julia_idx as usize))
                        } else {
                            None
                        }
                    } else {
                        None
                    }
                } else {
                    None
                };
            });
        } else {
            // For non-Option types, parameter is required
            if is_string_ref(param_type) {
                arg_parsers.push(quote! {
                    let #param_name = if let serde_json::Value::Object(o) = &args {
                        if let Some(serde_json::Value::Array(v)) = o.get("_v") {
                            v.get(#julia_idx as usize)
                                .and_then(|vv| {
                                    if let Some(s) = vv.as_str() {
                                        Some(s.to_string())
                                    } else if let serde_json::Value::Object(obj) = vv {
                                        obj.get("_v").and_then(|val| val.as_str()).map(|s| s.to_string())
                                    } else {
                                        None
                                    }
                                })
                                .ok_or_else(|| anyhow::anyhow!(concat!("missing or invalid ", #param_name_str)))?
                        } else {
                            return Err(anyhow::anyhow!("args._v is not an array"));
                        }
                    } else {
                        return Err(anyhow::anyhow!("args is not a Tuple"));
                    };
                });
            } else {
                // For other types, try to deserialize from JSON
                arg_parsers.push(quote! {
                    let #param_name = if let serde_json::Value::Object(o) = &args {
                        if let Some(serde_json::Value::Array(v)) = o.get("_v") {
                            v.get(#julia_idx as usize)
                                .and_then(|vv| serde_json::from_value(vv.clone()).ok())
                                .ok_or_else(|| anyhow::anyhow!(concat!("missing or invalid ", #param_name_str)))?
                        } else {
                            return Err(anyhow::anyhow!("args._v is not an array"));
                        }
                    } else {
                        return Err(anyhow::anyhow!("args is not a Tuple"));
                    };
                });
            }
        }
    }

    // Generate call to implementation
    let impl_call_args = impl_param_names.iter().zip(impl_params.iter()).map(|(name, (_, _, idx_opt))| {
        if idx_opt.is_none() {
            // id parameter - pass as id (from handler parameter)
            quote! { id }
        } else {
            // Regular parameter - pass as reference
            quote! { &#name }
        }
    });

    // Extract parameter signatures for the clean function
    let impl_param_sigs = impl_params.iter().map(|(name, ty, _)| {
        quote! { #name: #ty }
    });

    let vis = &input_fn.vis;
    let impl_block = &input_fn.block;
    let impl_sig_output = &input_fn.sig.output;
    let impl_attrs = &input_fn.attrs;

    let expanded = quote! {
        // Keep original implementation function
        #(#impl_attrs)*
        #vis async fn #impl_name(
            state: &crate::AppState,
            #(#impl_param_sigs),*
        ) #impl_sig_output {
            #impl_block
        }

        // Generate handler function that parses args/kwargs
        pub async fn #handler_name(
            state: &crate::AppState,
            id: &crate::processing_graph::NodeId,
            args: serde_json::Value,
            kwargs: serde_json::Value
        ) -> anyhow::Result<serde_json::Value> {
            // Parse arguments from Julia-style Tuple and NamedTuple
            #(#arg_parsers)*

            // Call the implementation
            let result = #impl_name(state, #(#impl_call_args),*).await?;
            Ok(result)
        }

        // Registration helper
        #[allow(dead_code)]
        pub fn #register_name() {
            crate::processing_graph::register(
                #module_name,
                #processing_func_name,
                |state, id, args, kwargs| Box::pin(async move {
                    #handler_name(&state, &id, args, kwargs).await
                })
            );
        }
    };

    TokenStream::from(expanded)
}

fn is_option_type(ty: &syn::Type) -> bool {
    if let syn::Type::Path(type_path) = ty {
        if let Some(segment) = type_path.path.segments.last() {
            return segment.ident == "Option";
        }
    }
    false
}

fn is_string_ref(ty: &syn::Type) -> bool {
    if let syn::Type::Reference(type_ref) = ty {
        if let syn::Type::Path(type_path) = &*type_ref.elem {
            if let Some(segment) = type_path.path.segments.last() {
                return segment.ident == "String";
            }
        }
    }
    false
}
