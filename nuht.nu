# This Nushell module contains utilities to analyze the usage statistics of Nushell commands based on user history.

# Calculates and aggregates statistics for Nushell command usage across .nu files and command histories.
# It includes features for normalization of data, creation of visual graphs and bars to represent data,
# and benchmarking command usage against submissions from other users.

# https://github.com/nushell-prophet/nu-history-tools

use nu-utils [bar spark normalize cprint 'fill non-exist' ansi-alternate]

# Calculates statistics for the current user's command history.
export def nu-hist-stats [
    --pick_users    # This flag triggers an interactive user selection to filter benchmarks during script execution
    --nickname: string = 'WriteYourNick' # The nick to use for resulting stats (can be submitted to common stats repo)
] {
    $env.freq-hist.pick-users = $pick_users

    cprint --after 2 --frame '*' 'nu-commands-frequency-stats v2.0'

    let $compatible_versions = ['0.88.1']
    let $running_version = (version | get version)
    let $temp_history_file = ($nu.temp-path | path join $'nushell_hist_for_ast(random chars).nu')

    history-save $temp_history_file

    if $running_version not-in $compatible_versions {
        cprint --after 1 --before 1 $'This script was tested on *($compatible_versions)*. You have *($running_version)*.
            If you have problems running this script, consider upgrading Nushell.'
    }

    cprint --before 1 --after 2 'The script is calculating stats now.
        On an M1 Mac with a history of ~50,000 entries, It runs for about a minute. Please wait'

    let $res = (nu-file-stats --extra_graphs $temp_history_file)

    $res
    | save-stats-for-submission $nickname

    $res
    | make-benchmarks
}

export def save-stats-for-submission [
    nickname: string
] {
    let $input = $in

    let $submissions_path = (
        pwd | path join 'stats_submissions'   # if this script is executed from the git folder of nu-history-tools module, there should be a 'submissions' folder
        | if ($in | path exists) { } else {
            error make {msg: `Please run this script for the root of it's git repositor folder`}
        }
        | path join $'v2+($nickname).csv'
    )

    $input
    | select -i name freq
    | save -f $submissions_path

    cprint --after 2 $'Your stats have been saved to *($submissions_path)*. Please consider donating them
        to the original repository *https://github.com/nushell-prophet/nu-history-tools/tree/main/stats_submissions*.'
}

# Calculate stats of commands in given .nu files
# > glob **/*.nu --not ['**/themes/**/' '**/before_v0.60/**' '**/custom-completions/**'] | nu-files-stats
export def nu-files-stats [
    ...file_paths: path
] {
    $in
    | default $file_paths
    | par-each {|i| nu-file-stats $i}
    | flatten
    | where freq != null
    | group-by name
    | values
    | par-each {|i| $i | get 0 | upsert freq ($i.freq | math sum)}
    | normalize freq
    | upsert freq_norm_bar {|i| bar $i.freq_norm --width ('freq_norm_bar' | str length)}
    | sort-by freq -r
}

# Calculate stats of command usage in a specified `.nu` file.
# Generates additional graphs and normalizes frequency data upon request.
# Saves the output to a user-defined path for contributing results to the `nu-history-tools` repo.
export def nu-file-stats [
    path: path
    --normalize_freq            # Adds a normalized frequency column to the output.
    --extra_graphs              # Includes frequency histogram and timeline sparklines in the output.
    --include_0_freq_commands   # Include all the historical Nushell commands
] {
    let $ast_data = (
        nu --ide-ast $path --no-config-file --no-std-lib
        | from json
        | where shape in ['shape_internalcall' 'keyword']
    )

    let $freq_table = ($ast_data | get content | uniq --count | rename name freq)

    let $freq_builtins_only = (
        commands-all
        | reject first_tag last_tag crate
        | join $freq_table -l name # but left join we make sure that only standard commands are included into results
        | if $include_0_freq_commands {
            default 0 freq
        } else {
            where freq? != null
        }
    )

    $freq_builtins_only
    | if $normalize_freq or $extra_graphs {
        normalize freq
    } else {}
    | if $extra_graphs {
        make_extra_graphs $ast_data
    } else {}
}

# Helper function to open a submission file and shape the data for further needs
def open_submission [
    filename: path
] {
    open $filename
    | if ('command_type' in ($in | columns)) {
        reject command_type
    } else {}
    | join (commands-all) --right name
    | default 0 freq
    | normalize freq
    | upsert freq_norm_bar {|i| bar $i.freq_norm -w ('freq_norm_bar' | str length)}
    | {commands: $in}
    | upsert user ($filename | path basename | str replace -r '.*\+(.*)\.csv' '$1')
    | upsert command_entries {|i| $i.commands.freq | math sum} # The total count of command entries in history of the current user
}

# Parses submitted stats from a folder and aggregates them for benchmarking.
# Can interactively select users to include in the analysis.
export def aggregate-submissions [
    --submissions_path: path = 'stats_submissions'  # A path to a folder that contains submitted results.
    --pick_users                                    # This flag triggers interactive user selection during script execution.
] {
    cprint -f '*' --after 2 -h grey --keep_single_breaks 'Aggregated stats of other users for benchmarks.
        *They will be displayed in the final table*.'

    let $user_selection_dialog = $pick_users or ($env.freq-hist?.pick-users? | default false)

    let $aggregated_submissions = (
        ls $submissions_path --full-paths
        | where ($it.name | path parse | get extension) == 'csv'
        | sort-by size -r
        | get name
        | where $it !~ 'WriteYourNick.csv' # default output
        | if $user_selection_dialog {
            each {|i| $i | path relative-to (pwd)} # make paths shorter for 'input list'
            | input list --multi
        } else {}
        | par-each {|filename| open_submission $filename}
        | sort-by command_entries -r
    )

    let $ordered_users = (
        $aggregated_submissions
        | select user command_entries
        | enumerate
        | flatten
        | upsert user {|i| $'(ansi-alternate $i.index)($i.user)(ansi reset)'}
    )

    if not $user_selection_dialog {
        cprint --after 2 '*freq_by_user* (frequency norm by user) includes stats from all users.
        You can pick some of them by providing the *--pick_users* flag: *nu-hist-stats --pick_users* or
        *aggregate-submissions --pick_users*.'
    }

    print $ordered_users

    let $grouped_statistics = (
        $aggregated_submissions
        | select commands user
        | flatten
        | flatten
        | group-by name
    )

    let $user_sparklines = (
        $grouped_statistics
        | values
        | each {|b| {name: $b.name.0, freq_by_user: (spark $b.freq_norm --colors)}}
        | transpose -idr
    )

    let $final_analytics = (
        $grouped_statistics
        | items { |name b|
            {
                name: $name,
                category: $b.category.0,
                freq_overall: ($b.freq | math sum),
                users_count: ($b.freq | where $it > 0 | length),
                f_n_per_user: ($b.freq_norm | math avg),
                freq_by_user: ($user_sparklines | get $name),
            }
        }
        | upsert importance {
            |i| ($i.users_count * $i.f_n_per_user) | math sqrt # geometric mean
        }
        | normalize importance --suffix ''
        | sort-by importance -r
        | upsert importance_b {|i| bar $i.importance --width ('importance_b' | str length)}
    );

    $final_analytics
    | join -l (commands-all | reject category) name     # here we join table to have info about github tags, when commands were introduced
}

# Create benchmark columns for piped-in stats.
# Adds extra columns to the data for visual representation and calculation of importance.
export def make-benchmarks [] {
    let $data = $in

    let $benchmarks = (
        aggregate-submissions
        | select name importance importance_b freq_by_user
    );

    cprint -f '*' 'Resulting table'

    cprint --keep_single_breaks --after 2 '*A note about some columns*:
    - *freq* - indicates the overall frequency of use of the given command for the currently analyzed source
    - *freq_norm* - represents the overall frequency normalized
    - *freq_norm_bar* - shows the overall frequency normalized in a bar chart format
    - *timeline* - displays the dynamics, indicating when the command was used throughout your history
    - *importance* - calculated as the geometric mean of the number of users who used this command and the average normalized frequency
    - *freq_by_user* (frequency norm by user) - each bar in the sparkline column represents one user (order is shown in the table above).'

    $data
    | join -l $benchmarks name
    | upsert importance {|i| $i | get -i importance | default 0}
    | sort-by importance -r -n
    | fill non-exist ''
}

# Provides a list with all commands ever implemented in Nushell and their crates.
# Useful for cross-referencing current commands against historical data.
# > use nuht.nu commands-all; let $res = commands-all; $res | last 3
# ╭────name─────┬─────crate──────┬first_tag┬last_tag┬──category──╮
# │ unfold      │ nu-command     │ 0.86.0  │ 0.86.0 │ generators │
# │ url decode  │ nu-command     │ 0.86.0  │ 0.86.0 │ strings    │
# │ hash sha256 │ not_parsed_yet │ 0.86.0  │ 0.86.0 │ hash       │
# ╰─────────────┴────────────────┴─────────┴────────┴────────────╯
export def commands-all [] {
    let $crate_history = (open crates_parsing/cmds_by_crates_and_tags.csv)

    let $current_command_list = (
        help commands
        | select name category command_type
        | where command_type in ['builtin' 'keyword']
        | reject command_type
    )

    let $ver = (version | get version)

    # The $default_command_data is used if there is no crates parsing history.
    # You can update the CSV file by running crates_parsing/crates_parsing.nu
    let $default_command_data = (
        $current_command_list
        | select name
        | upsert crate not_parsed_yet
        | upsert first_tag $ver
        | upsert last_tag $ver
    )

    $crate_history
    | append $default_command_data
    | uniq-by name
    | join -l $current_command_list name
}

# Creates extra graphical representations for command usage over time.
# Serves as a helper function within the script for visual data analysis.
def make_extra_graphs [
    $ast_data
] {
    let $table_in = $in
    let $hist_for_timeline = (
        $ast_data
        | upsert start {|i| $i.span.start}
        | select content start
        | upsert start {|i| $i.start // 100_000}
        | uniq --count
        | flatten
    );

    let $default_bins = (
        $hist_for_timeline
        | get start
        | uniq
        | sort
        | reduce -f {} {|a b| $b | merge {$a: 0}}
    )

    let $sparkline_data = (
        $hist_for_timeline
        | group-by content
        | items {|a b|
            $default_bins
            | merge ($b | select start count | transpose -idr)
            | values
            | spark $in
            | { $a: $in }
        }
        | reduce -f {} {|a b| $a | merge $b}
    )

    $table_in
    | upsert 'freq_norm_bar' {|i| bar $i.freq_norm --width 10}
    | upsert timeline {
        |i| $sparkline_data
        | get -i $i.name
    }
}

# Combine history from sql and txt files and save it as a `.nu` file to the specified destination.
def history-save [
    destination_path: path
] {
    let $history_txt_path = ($nu.history-path | str replace sqlite3 'txt')

    mut history_txt = []

    if (($env.config.history.file_format == 'sqlite') and ($history_txt_path | path exists)) {

        cprint --after 2 $'Your history is in *sqlite* format and will be used for analysis.
        Additionally, you have history in *txt* format, which consists of *($history_txt_path | open | lines | length)
        entries*. It will be used for analysis as well.'

        $history_txt = ( open $history_txt_path | lines )
    }

    history
    | get command
    | prepend $history_txt
    | str join $';(char nl)'
    | save -f $destination_path
}
