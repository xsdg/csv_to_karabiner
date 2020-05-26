#!/usr/bin/ruby

require 'csv'
require 'json'

module Enumerable
  def stable_sort
    sort_by.with_index { |x, idx| [x, idx] }
  end

  def stable_sort_by
    sort_by.with_index { |x, idx| [yield(x), idx] }
  end
end

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

# Generates and returns a single rule.
def rule_stanza(desc, manipulators)
    return {
        'description' => desc,
        'manipulators' => manipulators
    }
end

# Helpers to generate and return single manipulations.
def basic_keypress_stanza(out_key_code, modifiers, key_defs)
    impl = {
        'type' => 'basic',
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

# Default parameters:
# simultaneous_threshold_milliseconds: 100
# to_if_alone_timeout_milliseconds: 250
# to_if_held_down_threshold_milliseconds: 250
def hold_modifier_stanza(var_name, key_defs)
    return {
        'type' => 'basic',
        'from' => {
            'modifiers' => {
                'optional' => ['any']
            },
            'simultaneous' => key_defs,
        },
        'to_if_held_down' => [
            {
                'repeat': false,
                'set_variable': {
                    'name' => var_name,
                    'value' => 1,
                }
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
        'from' => {
            'key_code' => key_def,
            'modifiers' => {
                'optional' => ['any']
            },
            # TODO: can we support this?
            # 'simultaneous' => key_defs,
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

# Helper function to turn an array of key actions into key_code stanzas.
def key_defs(actions)
    return actions.map{|(in_key, action)| {'key_code' => in_key}}
end

# State variables for parsing the CSV.
manipulators = {'basic' => [], 'hold_mod' => [], 'hold_press' => []}
column = {}
key_list = []
basic_index = {}
hold_index = {}

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
    # corresponding (by index) element from the second array.  In this case, we
    # get each key name with an empty (nil) action, "press", or "hold".
    all_actions = key_list.zip(row)[column['key 0']..column['key 9']]
    actions = all_actions.reject {|(key, action)| action.nil?}

    # Print some diagnostic output.
    $stderr.puts [out_key, actions].inspect

    # Partitions keys by type, deduces any modifiers, and creates manipulator
    # stanzas for each of them.
    # FIXME add support for shift key (or lazy, generally)
    press_keys, hold_keys = actions.partition {
        |(in_key, action)| action == 'press'
    }
    modifiers = (row[column['modifiers']] || '').split(%r{\s*\+\s*})

    if (press_keys.empty?)
        # This is not valid.
        raise "Invalid specification; no press keys specified: #{row.inspect}"
    elsif (hold_keys.empty?)
        # The summary is a concatenated string of key_codes.
        key_summary = press_keys.map{|(key, action)| key}.sort.join
        key_stanza = basic_keypress_stanza(
                out_key, modifiers, key_defs(press_keys))

        # Print some more diagnostic output.
        $stderr.puts('press')
        $stderr.puts key_stanza.inspect
        $stderr.puts

        # Record the new manipulator, as well as a keyed index entry to it.
        manipulators['basic'] << key_stanza
        basic_index[key_summary] = manipulators['basic'].last
    else
        if (press_keys.size > 1)
            raise "Hold + multi-press is not supported: #{row.inspect}"
        end
        press_key = press_keys.first[0]

        # The summary is a concatenated string of key_codes.
        hold_summary = hold_keys.map{|(key, action)| key}.sort.join
        # A duplicate like this will occur if multiple hold-and-press key
        # combinations share a hold combination.  This avoids creating redundant
        # entries.
        skip_hold_mod = hold_index.has_key? hold_summary

        var_name = 'hold_' + hold_summary
        mod_stanza = hold_modifier_stanza(var_name, key_defs(hold_keys))
        key_stanza = hold_keypress_stanza(
                out_key, var_name, modifiers, press_key)

        # More diagnostic output.
        if skip_hold_mod
            $stderr.puts 'truncated hold'
        else
            $stderr.puts 'hold'
        end
        $stderr.puts mod_stanza.inspect
        $stderr.puts key_stanza.inspect
        $stderr.puts

        # Record the new manipulator, as well as a keyed index entry to it.
        # For hold-and-press key combinations, the held-key combination and the
        # pressed key combination go in separate rules.
        manipulators['hold_press'] << key_stanza
        if not skip_hold_mod
            manipulators['hold_mod'] << mod_stanza
            hold_index[hold_summary] = manipulators['hold_mod'].last
        end
    end
}

# This workaround handles the case where the press keys for a basic_keypress
# coincide with the _held_ keys for a hold-and-press combination.  Because all
# hold_modifier stanzas precede all basic_keypress stanzas, the hold_modifier
# stanza will steal the keypress in all cases, including when the triggering key
# combination is only pressed momentarily and not held.
#
# To mitigate that, we also add the 'to' output from the basic_keypress stanza
# to the 'to_if_alone' output from the hold_modifier stanza.
(basic_index.keys & hold_index.keys).each {
    |key|
    $stderr.puts "Double key: #{key}"
    $stderr.puts hold_index[key].inspect
    hold_index[key]['to_if_alone'] = [
        {
            'repeat': false,
            'key_code': basic_index[key]['to'][0]['key_code'],
        }
    ]
    $stderr.puts hold_index[key].inspect
    $stderr.puts
}

# Sort with greatest number of simultaneously-held keys first, but in a way
# that always retains the 'hold_mod' manipulators before the 'hold_press'
# manipulators before the 'basic' manipulators within each partition.
all_manips = (manipulators['hold_mod'] + manipulators['hold_press']
              + manipulators['basic'])
all_manips = all_manips.stable_sort_by {
    |manip|
    # If no 'simultaneous' key, substitute 1.
    -1 * (manip['from']['simultaneous'].size rescue 1)
}

# Finally, generate the rule stanzas and create the finished configuration.
rules = rule_stanza('rules', all_manips)

structure = document([rules])

# Finished generating the structure.  Now just convert to JSON and print.
if (true)
    $stderr.puts "Printing finished product to stdout"
    puts JSON.pretty_generate(structure)
else
    $stderr.puts structure.inspect
end
