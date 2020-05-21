#!/usr/bin/ruby

require 'csv'
require 'json'

# Expects a filename to be specified as the first argument, reads the file with
# that name, and parses that file as a CSV document.
input = CSV.new(File.read(ARGV[0]))

# Sets up some templates that we'll use to generate a document structure.  This
# document structure will be converted to JSON at the end.
structure = {
    'title' => 'something',
    'rules' => []
}

# A single rule
rule_tmpl = {
    'description' => 'It\'s the rule, obviously',
    'manipulators' => []
}

# A single manipulation
press_tmpl = {
    'type' => 'basic',
    'parameters' => {
        'basic.simultaneous_threshold_milliseconds' => 100
    },
    'from' => {
        'modifiers' => {
            'optional' => ['any']
        },
        'simultaneous' => [
        ],
    },
    'to' => [
        {
            'repeat': false,
            'key_code' => nil
        },
    ],
}

hold_tmpl = {
    'type' => 'basic',
    'parameters' => {
        'basic.simultaneous_threshold_milliseconds' => 5000
    },
    'from' => {
        'modifiers' => {
            'optional' => ['any']
        },
        'simultaneous' => [
        ],
    },
    'to' => [
        {
            'repeat': false,
            'key_code' => nil
        },
    ],
}

# For now, we just put everything into a single rule.
rule_impl = Marshal.load(Marshal.dump(rule_tmpl))
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

    # The `shift` method removes the first item from the array and returns it
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
    # Makes a deep copy of the appropriate template that we can fill in without
    # modifying the original.
    has_hold = actions.flatten.include? 'hold'
    key_impl = Marshal.load(Marshal.dump(has_hold ? hold_tmpl : press_tmpl))

    # For each involved key, add it to the "from" configuration.
    actions.each {
        |(in_key, action)|
        key_impl['from']['simultaneous'] << {'key_code' => in_key}
    }

    # Sets the output key code, and any modifiers.
    key_impl['to'][0]['key_code'] = out_key
    key_impl['to'][0]['lazy'] = true if out_key_is_lazy

    # If any modifiers were specified, add them to the out key also.
    if (not row[column['modifiers']].nil?)
        key_impl['to'][0]['modifiers'] = \
            row[column['modifiers']].split(%r{\s*\+\s*})
    end

    # Print some more diagnostic output.
    $stderr.puts key_impl.inspect
    $stderr.puts

    rule_impl['manipulators'] << key_impl
}

# Sort with greatest number of simultaneously-held keys first.
rule_impl['manipulators'].sort_by! {
    |manip|
    -1 * manip['from']['simultaneous'].size
}

structure['rules'] << rule_impl

# Finished generating the structure.  Now just convert to JSON and print.
if (true)
    $stderr.puts "Printing finished product to stdout"
    puts JSON.pretty_generate(structure)
else
    $stderr.puts structure.inspect
end
