#!/usr/bin/ruby

require 'csv'
require 'json'

# Expects a filename to be specified as the first argument, reads the file with
# that name, and parses that file as a CSV document.
input = CSV.new(File.read(ARGV[0]))

# Sets up some templates that we'll use to generate a document structure.  This
# document structure will be converted to JSON at the end.
def document(rules)
    return {
        'title' => 'From csv key map; Generated at ' + Time.now.to_s,
        'rules' => rules
    }
end

# A single rule
def rule_stanza(desc, manipulators)
    return {
        'description' => desc,
        'manipulators' => manipulators
    }
end

# A single manipulation
def basic_keypress_stanza(out_key_code, modifiers, key_defs)
    impl = {
        'type' => 'basic',
        'parameters' => {
            'basic.simultaneous_threshold_milliseconds' => 100
        },
        'from' => {
            'modifiers' => {
                'optional' => ['any']
            },
            'simultaneous' => key_defs,
        },
        'to' => [
            {
                'repeat': false,
                'key_code' => out_key_code,
            },
        ],
    }

    if (not modifiers.empty?)
        impl['to'][0]['modifiers'] = modifiers
    end

    return impl
end

def hold_modifier_stanza(var_name, key_defs)
    return {
        'type' => 'basic',
        'parameters' => {
            'basic.simultaneous_threshold_milliseconds' => 100,
            'basic.to_if_alone_timeout_milliseconds' => 250,
            'basic.to_if_held_down_threshold_milliseconds' => 250,
        },
        'from' => {
            'modifiers' => {
                'optional' => ['any']
            },
            'simultaneous' => key_defs,
            #'simultaneous_options' => [
            #    'detect_key_down_uninterruptedly' => true,
            #    'key_up_when' => 'all',
            #],
        },
        'to_if_held_down' => [
            {
                'repeat': false,
                'set_variable': {
                    'name' => var_name,
                    'value' => 1,
                }
                # lazy?
            },
        ],
        'to_after_key_up' => [
            {
                'set_variable': {
                    'name' => var_name,
                    'value' => 0,
                }
            },
        ],
    }
end

def hold_keypress_stanza(out_key_code, hold_var_name, modifiers, key_def)
    impl = {
        'type' => 'basic',
        'parameters' => {
            'basic.simultaneous_threshold_milliseconds' => 100
        },
        'from' => {
            'key_code' => key_def,
            'modifiers' => {
                'optional' => ['any']
            },
            #'simultaneous' => key_defs,
            #'simultaneous_options' => [
            #    'detect_key_down_uninterruptedly' => true,
            #    'key_up_when' => 'any',
            #],
        },
        'to' => [
            {
                'repeat': false,
                'key_code' => out_key_code,
            }
        ],
        'conditions' => [
            {
                'type' => 'variable_if',
                'name' => hold_var_name,
                'value' => 1
            },
        ],
    }

    if (not modifiers.empty?)
        impl['to'][0]['modifiers'] = modifiers
    end

    return impl
end

def key_defs(actions)
    return actions.map{|(in_key, action)| {'key_code' => in_key}}
end

# Get ready to start parsing the CSV.
manipulators = {'basic' => [], 'hold_mod' => [], 'hold_press' => []}
column = {}
key_list = []

# For each row in the CSV that we imported above...
input.each_with_index {
    |row, idx|
    # Make everything lowercase by convention.
    row.map! {|val| val.downcase if val}

    # Parse the two-line header.
    if (idx == 0)
        row.each_with_index {
            |col, cidx|
            column[col] = cidx
        }
        next
    elsif (idx == 1)
        key_list = row
        $stderr.puts key_list.inspect
        next
    end

    if (not row[column['ignore']].nil?)
        next
    end

    out_key = row[column['key']]
    # If the out key stars with the special prefix "lazy ", drop that prefix and
    # set this flag to true; otherwise, set to false.
    out_key_is_lazy = !!out_key.delete_prefix!('lazy ')

    # The `zip` method pairs each element from the first array with the
    # corresponding (by index) array from the second array.  In this case, we
    # get each key name with an empty (nil) action or an action that is some
    # variation of "press" or "hold".
    all_actions = key_list.zip(row)[column['key 0']..column['key 9']]
    actions = all_actions.reject {|(key, action)| action.nil?}

    # Print some diagnostic output.
    $stderr.puts [out_key, actions].inspect

    # Partitions keys by type, deduces any modifiers, and creates manipulator
    # stanzas for each of them.
    # FIXME lazy
    press_keys, hold_keys = actions.partition {
        |(in_key, action)| action == 'press'
    }
    modifiers = (row[column['modifiers']] || '').split(%r{\s*\+\s*})
    if (press_keys.empty?)
        # This is not valid.
        raise "Invalid specification; no press keys specified: #{row.inspect}"
    elsif (hold_keys.empty?)
        key_stanza = basic_keypress_stanza(
                out_key, modifiers, key_defs(press_keys))

        # Print some more diagnostic output.
        $stderr.puts('press')
        $stderr.puts key_stanza.inspect
        $stderr.puts

        manipulators['basic'] << key_stanza
    else
        if (press_keys.size > 1)
            raise "Hold + multi-press is not supported: #{row.inspect}"
        end
        press_key = press_keys.first[0]

        var_name = 'hold_' + hold_keys.map{|(key, action)| key}.sort.join
        mod_stanza = hold_modifier_stanza(var_name, key_defs(hold_keys))
        key_stanza = hold_keypress_stanza(
                out_key, var_name, modifiers, press_key)

        $stderr.puts 'hold'
        $stderr.puts mod_stanza.inspect
        $stderr.puts key_stanza.inspect
        $stderr.puts

        manipulators['hold_press'] << key_stanza
        manipulators['hold_mod'] << mod_stanza
    end
}

# Sort with greatest number of simultaneously-held keys first.
manipulators['basic'].sort_by! {
    |manip|
    # If no 'simultaneous' key, substitute 1.
    -1 * (manip['from']['simultaneous'].size rescue 1)
}
manipulators['hold_mod'].sort_by! {
    |manip|
    -1 * manip['from']['simultaneous'].size
}.uniq!

basic_rule = rule_stanza('basic keypress rules', manipulators['basic'])
hold_mod_rule = rule_stanza('hold modifier rules', manipulators['hold_mod'])
hold_press_rule = rule_stanza('hold keypress rules', manipulators['hold_press'])

structure = document([hold_mod_rule, hold_press_rule, basic_rule])

# Finished generating the structure.  Now just convert to JSON and print.
if (true)
    $stderr.puts "Printing finished product to stdout"
    puts JSON.pretty_generate(structure)
else
    $stderr.puts structure.inspect
end
