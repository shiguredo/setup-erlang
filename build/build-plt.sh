#!/usr/bin/env bash
#
# Build the dialyzer base PLT for a release layout of Erlang/OTP.
#
# rebar3 looks for the base PLT of the incremental mode at
#
#     $HOME/.cache/rebar3/rebar3_<OTP release>_iplt
#
# and uses it as the seed of every project PLT. The file is a pure function of
# the Erlang/OTP installation, so it can be built once per release.
#
# The applications and the file expansion below must match rebar3's defaults
# (base_plt_apps = [erts, crypto, kernel, stdlib] and app_ebin/1 in
# rebar_prv_dialyzer.erl). Extra modules would be treated as removed by
# rebar3, and the removal would trigger additional analysis of their
# dependents.
#
set -euo pipefail

: "${ERLANG_ROOT:?ERLANG_ROOT is required (example: /path/to/erlang)}"
: "${OUTPUT_PLT:?OUTPUT_PLT is required (example: out/otp-x86_64-unknown-linux-gnu.iplt)}"

die() {
    printf 'build-plt: %s\n' "$1" >&2
    exit 1
}

[[ -d "${ERLANG_ROOT}" ]] || die "Erlang/OTP directory not found: ${ERLANG_ROOT}"
erlang_root="$(cd "${ERLANG_ROOT}" && pwd -P)"
[[ -x "${erlang_root}/bin/erl" ]] || die "erl is not found in ${erlang_root}"
[[ -x "${erlang_root}/bin/dialyzer" ]] || die "dialyzer is not found in ${erlang_root}"

mkdir -p "$(dirname "${OUTPUT_PLT}")"
output_plt="$(cd "$(dirname "${OUTPUT_PLT}")" && pwd -P)/$(basename "${OUTPUT_PLT}")"
tmp_plt="${output_plt}.tmp"
rm -f "${tmp_plt}"

export PLT_OUTPUT="${tmp_plt}"

# rebar3 の incremental_base_plt/3 と同じオプションでベース PLT を生成する
if ! "${erlang_root}/bin/erl" -noshell -eval '
    try
        Apps = [erts, crypto, kernel, stdlib],
        Files = lists:flatmap(
            fun(App) ->
                AppDir = code:lib_dir(App),
                case AppDir of
                    {error, bad_name} ->
                        erlang:error({unknown_application, App});
                    _ ->
                        EbinDir = case filelib:is_dir(filename:join(AppDir, "ebin")) of
                                      true -> filename:join(AppDir, "ebin");
                                      false -> filename:join(AppDir, "preloaded/ebin")
                                  end,
                        case filelib:wildcard(filename:join(EbinDir, "*.beam")) of
                            [] -> erlang:error({no_beam_files, App, EbinDir});
                            Beams -> Beams
                        end
                end
            end, Apps),
        Output = os:getenv("PLT_OUTPUT"),
        io:format("build-plt: analyzing ~b files for the base PLT~n", [length(Files)]),
        _ = dialyzer:run([{analysis_type, incremental},
                          {get_warnings, false},
                          {from, byte_code},
                          {files, Files},
                          {output_plt, Output}]),
        halt(0)
    catch
        Class:Reason:Stacktrace ->
            io:format(standard_error, "build-plt: ~p:~p~n~p~n", [Class, Reason, Stacktrace]),
            halt(1)
    end.'; then
    rm -f "${tmp_plt}"
    die "failed to build the base PLT for ${erlang_root}"
fi

[[ -s "${tmp_plt}" ]] || die "dialyzer did not create a base PLT for ${erlang_root}"

# incremental PLT として読めることと、モジュール数を確認する
export PLT_CHECK="${tmp_plt}"
if ! "${erlang_root}/bin/erl" -noshell -eval '
    File = os:getenv("PLT_CHECK"),
    case dialyzer:plt_info(File) of
        {ok, {incremental, [{modules, Modules}]}} ->
            io:format("build-plt: the base PLT contains ~b modules~n", [length(Modules)]),
            halt(0);
        Other ->
            io:format(standard_error, "build-plt: unexpected PLT info: ~p~n", [Other]),
            halt(1)
    end.'; then
    rm -f "${tmp_plt}"
    die "the generated base PLT is not readable: ${tmp_plt}"
fi

chmod 0644 "${tmp_plt}"
mv "${tmp_plt}" "${output_plt}"
printf 'build-plt: wrote %s\n' "${output_plt}"
