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

# Adds delete_prefix and delete_prefix! methods if needed for compatibility with
# older versions of ruby.
if (not "".methods.include? :delete_prefix)
    $stderr.puts "NOTE: patching delete_prefix method into String class for " \
                 "old ruby version"
    class String
        def delete_prefix(prefix)
            if (self[0...prefix.length] == prefix)
                return self[prefix.length..-1]
            end
            return self
        end

        def delete_prefix!(prefix)
            maybe_update = self.delete_prefix(prefix)
            return nil if maybe_update == self

            self[0..-1] = maybe_update
            return true
        end
    end
end

if (ARGV.empty?)
    puts "Usage:"
    puts "#$0 input.csv > output.json"
    exit 1
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
def to_stanza_for_basic_keypress(out_key_code, modifiers, out_key_is_repeated,
                                 out_mouse, out_mouse_is_repeated, out_custom,
                                 out_custom_is_repeated)
    impl = {
        'to' => []
    }

    # Adds a "key_code" entry, if out_key_code is defined.
    if (not out_key_code.nil?)
        to_impl = {}
        to_impl['repeat'] = out_key_is_repeated
        to_impl['key_code'] = out_key_code

        if (not modifiers.empty?)
            to_impl['modifiers'] = modifiers
        end

        impl['to'] << to_impl
    end

    # Adds one mouse-related entry for each pair in out_mouse.
    if (not out_mouse.nil?)
        out_mouse.each {
            |(action, value)|
            to_impl = {}
            to_impl['repeat'] = out_mouse_is_repeated

            if (action == 'button')
                to_impl['pointing_button'] = "button#{value}"
            else
                to_impl['mouse_key'] = {action => value.to_i}
            end

            impl['to'] << to_impl
        }
    end

    # Adds one custom entry, if out_custom is defined.  The first token is used
    # as the key, and the rest of the string is used as the value.
    if (not out_custom.nil?)
        to_impl = {}
        to_impl['repeat'] = out_custom_is_repeated
        to_impl[out_custom[0]] = out_custom[1]
        impl['to'] << to_impl
    end

    return impl
end

def basic_keypress_stanza(out_key_code, modifiers, out_key_is_repeated,
                          out_mouse, out_mouse_is_repeated, out_custom,
                          out_custom_is_repeated, key_defs)
    impl = {
        'type' => 'basic',
        'from' => {
            'modifiers' => {
                'optional' => ['any']
            },
            'simultaneous' => key_defs,
        },
    }

    impl.merge!(to_stanza_for_basic_keypress(
            out_key_code, modifiers, out_key_is_repeated, out_mouse,
            out_mouse_is_repeated, out_custom, out_custom_is_repeated))

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

def hold_keypress_stanza(hold_var_name, out_key_code, modifiers,
                         out_key_is_repeated, out_mouse, out_mouse_is_repeated,
                         out_custom, out_custom_is_repeated, key_def)
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
        'conditions' => [
            {
                'type' => 'variable_if',
                'name' => hold_var_name,
                'value' => 1
            },
        ],
    }

    impl.merge!(to_stanza_for_basic_keypress(
            out_key_code, modifiers, out_key_is_repeated, out_mouse,
            out_mouse_is_repeated, out_custom, out_custom_is_repeated))

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
basic_repeat_index = {}

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

    # Stash the initial values (which may be modified later on).
    out_key = row[column['key']]
    out_mouse = row[column['mouse']]
    out_custom = row[column['custom action']]

    if (out_key.nil? and out_mouse.nil? and out_custom.nil?)
        raise "Invalid specification; no actions defined:\n#{row.inspect}"
    end

    # If the output actions start with the special prefix "repeat ", drop that
    # prefix and set this flag to true; otherwise, set to false.
    out_key_is_repeated = \
            out_key.nil? ? false : !!out_key.delete_prefix!('repeat ')
    out_mouse_is_repeated = \
            out_mouse.nil? ? false : !!out_mouse.delete_prefix!('repeat ')
    out_custom_is_repeated = \
            out_custom.nil? ? false : !!out_custom.delete_prefix!('repeat ')

    # If specified, interpret column contents as space-delimited key-value
    # pairs.  Otherwise, nil.
    out_mouse = Hash[ *out_mouse.split() ] unless out_mouse.nil?

    # If specified, interpret column contents as space-delimited key-value
    # pairs.  Otherwise, nil.
    out_custom = out_custom.split(/\s+/, 2) unless out_custom.nil?
    if (out_custom and out_custom.size < 2)
        raise "Invalid specification; custom action must have an argument:\n" \
              "#{row.inspect}"
    end

    # The `zip` method pairs each element from the first array with the
    # corresponding (by index) element from the second array.  In this case, we
    # get each key name with an empty (nil) action, "press", or "hold".
    all_actions = key_list.zip(row)[column['key 0']..column['key 9']]
    actions = all_actions.reject {|(key, action)| action.nil?}

    # Print some diagnostic output.
    $stderr.puts [out_key, out_mouse, out_custom, actions].inspect

    # Partitions keys by type, deduces any modifiers, and creates manipulator
    # stanzas for each of them.
    # FIXME add support for shift key (or lazy, generally)
    press_keys, hold_keys = actions.partition {
        |(in_key, action)| action == 'press'
    }
    modifiers = (row[column['modifiers']] || '').split(%r{\s*\+\s*})

    if (press_keys.empty?)
        # This is not valid.
        raise "Invalid specification; no press keys specified:\n#{row.inspect}"
    elsif (hold_keys.empty?)
        any_out_is_repeated = out_key_is_repeated or out_mouse_is_repeated \
                              or out_custom_is_repeated
        if (any_out_is_repeated)
            $stderr.puts "WARNING: Key repeat for press-only combinations " \
                    "is only valid when they don't coincide with the held " \
                    "keys of hold-and-press combinations.  If a collision is " \
                    "detected, an exception will be raised."
        end

        # The summary is a concatenated string of key_codes.
        key_summary = press_keys.map{|(key, action)| key}.sort.join
        key_stanza = basic_keypress_stanza(
                out_key, modifiers, out_key_is_repeated, out_mouse,
                out_mouse_is_repeated, out_custom, out_custom_is_repeated,
                key_defs(press_keys))

        # Print some more diagnostic output.
        $stderr.puts('press')
        $stderr.puts key_stanza.inspect
        $stderr.puts

        # Record the new manipulator, as well as a keyed index entry to it.
        manipulators['basic'] << key_stanza
        basic_index[key_summary] = manipulators['basic'].last
        if (any_out_is_repeated)
            basic_repeat_index[key_summary] = manipulators['basic'].last
        end
    else
        if (press_keys.size > 1)
            raise "Hold + multi-press is not supported:\n#{row.inspect}"
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
                var_name, out_key, modifiers, out_key_is_repeated, out_mouse,
                out_mouse_is_repeated, out_custom, out_custom_is_repeated,
                press_key)

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

repeat_collisions = basic_repeat_index.keys & hold_index.keys
if (not repeat_collisions.empty?)
    raise "Invalid specification: press-only keys can only have repeat " \
          "enabled when the don't coincide with the hold combination of " \
          "press-and-hold keys.  But collisions exist for these " \
          "combinations: #{repeat_collisions.inspect}"
end

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
    hold_index[key]['to_if_alone'] = basic_index[key]['to']

    $stderr.puts hold_index[key].inspect
    $stderr.puts
}

# Sort with greatest number of simultaneously-held keys first, but in a way
# that always retains the 'hold_mod' manipulators before the 'hold_press'
# manipulators before the 'basic' manipulators within each partition.
all_manips = (manipulators['hold_mod'] + manipulators['hold_press'] +
              manipulators['basic'])
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
