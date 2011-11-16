package DBIx::Custom::Next;
use Object::Simple -base;

our $VERSION = '0.20_01';
$VERSION = eval $VERSION;
use 5.008001;

use Carp 'croak';
use DBI;
use DBIx::Custom::Next::Result;
use DBIx::Custom::Next::Where;
use DBIx::Custom::Next::Model;
use DBIx::Custom::Next::Order;
use DBIx::Custom::Next::Util qw/_array_to_hash _subname/;
use DBIx::Custom::Next::Mapper;
use DBIx::Custom::Next::NotExists;
use Encode qw/encode encode_utf8 decode_utf8/;
use Scalar::Util qw/weaken/;

has [qw/connector dsn password quote user exclude_table user_table_info
        user_column_info/],
    option => sub { {} },
    default_option => sub {
        {
            RaiseError => 1,
            PrintError => 0,
            AutoCommit => 1
        }
    },
    filters => sub {
        {
            encode_utf8 => sub { encode_utf8($_[0]) },
            decode_utf8 => sub { decode_utf8($_[0]) }
        }
    },
    last_sql => '',
    models => sub { {} },
    now => sub {
        sub {
            my ($sec, $min, $hour, $mday, $mon, $year) = localtime;
            $mon++;
            $year += 1900;
            my $now = sprintf("%04d-%02d-%02d %02d:%02d:%02d",
              $year, $mon, $mday, $hour, $min, $sec);
            return $now;
        }
    },
    result_class  => 'DBIx::Custom::Next::Result',
    safety_character => '\w',
    separator => '.',
    stash => sub { {} };

sub available_datatype {
    my $self = shift;
    
    my $data_types = '';
    for my $i (-1000 .. 1000) {
         my $type_info = $self->dbh->type_info($i);
         my $data_type = $type_info->{DATA_TYPE};
         my $type_name = $type_info->{TYPE_NAME};
         $data_types .= "$data_type ($type_name)\n"
           if defined $data_type;
    }
    return "Data Type maybe equal to Type Name" unless $data_types;
    $data_types = "Data Type (Type name)\n" . $data_types;
    return $data_types;
}

sub available_typename {
    my $self = shift;
    
    # Type Names
    my $type_names = {};
    $self->each_column(sub {
        my ($self, $table, $column, $column_info) = @_;
        $type_names->{$column_info->{TYPE_NAME}} = 1
          if $column_info->{TYPE_NAME};
    });
    my @output = sort keys %$type_names;
    unshift @output, "Type Name";
    return join "\n", @output;
}

our $AUTOLOAD;
sub AUTOLOAD {
    my $self = shift;

    # Method name
    my ($package, $mname) = $AUTOLOAD =~ /^([\w\:]+)\:\:(\w+)$/;

    # Call method
    $self->{_methods} ||= {};
    if (my $method = $self->{_methods}->{$mname}) {
        return $self->$method(@_)
    }
    elsif ($self->{dbh} && (my $dbh_method = $self->dbh->can($mname))) {
        $self->dbh->$dbh_method(@_);
    }
    else {
        croak qq{Can't locate object method "$mname" via "$package" }
            . _subname;
    }
}

sub assign_clause {
    my ($self, $param, $opts) = @_;
    
    my $wrap = $opts->{wrap} || {};
    my ($q, $p) = split //, $self->q('');
    
    # Assign clause (performance is important)
    join(
      ', ',
      map {
          ref $param->{$_} eq 'SCALAR' ? "$q$_$p = " . ${$param->{$_}}
          : $wrap->{$_} ? "$q$_$p = " . $wrap->{$_}->(":$_")
          : "$q$_$p = :$_";
      } sort keys %$param
    );
}

sub column {
    my $self = shift;
    my $option = pop if ref $_[-1] eq 'HASH';
    my $real_table = shift;
    my $columns = shift;
    my $table = $option->{alias} || $real_table;
    
    # Columns
    unless (defined $columns) {
        $columns ||= $self->model($real_table)->columns;
    }
    
    # Separator
    my $separator = $self->separator;
    
    # Column clause
    my @column;
    $columns ||= [];
    push @column, $self->q($table) . "." . $self->q($_) .
      " as " . $self->q("${table}${separator}$_")
      for @$columns;
    
    return join (', ', @column);
}

sub connect {
    my $self = ref $_[0] ? shift : shift->new(@_);
    
    my $connector = $self->connector;
    
    if (!ref $connector && $connector) {
        require DBIx::Connector;
        
        my $dsn = $self->dsn;
        my $user = $self->user;
        my $password = $self->password;
        my $option = $self->option;
        my $connector = DBIx::Connector->new($dsn, $user, $password,
          {%{$self->default_option} , %$option});
        $self->connector($connector);
    }
    
    # Connect
    $self->dbh;
    
    return $self;
}

sub count { shift->select(column => 'count(*)', @_)->fetch_first->[0] }

sub dbh {
    my $self = shift;
    
    # Set
    if (@_) {
        $self->{dbh} = $_[0];
        
        return $self;
    }
    
    # Get
    else {
        # From Connction manager
        if (my $connector = $self->connector) {
            croak "connector must have dbh() method " . _subname
              unless ref $connector && $connector->can('dbh');
              
            $self->{dbh} = $connector->dbh;
        }
        
        # Connect
        $self->{dbh} ||= $self->_connect;
        
        # Quote
        unless (defined $self->quote) {
            my $driver = $self->_driver;
            my $quote =  $driver eq 'odbc' ? '[]'
                       : $driver eq 'ado' ? '[]'
                       : $driver eq 'mysql' ? '`'
                       : '"';
            $self->quote($quote);
        }
        
        return $self->{dbh};
    }
}

sub delete {
    my ($self, %opt) = @_;
    
    # Don't allow delete all rows
    croak qq{delete method where or id option must be specified } . _subname
      if !$opt{where} && !defined $opt{id} && !$opt{allow_delete_all};
    
    # Where
    my $w = $self->_where_clause_and_param($opt{where}, {},
      delete $opt{id}, $opt{primary_key}, $opt{table});

    # Delete statement
    my $sql = "delete ";
    $sql .= "$opt{prefix} " if defined $opt{prefix};
    $sql .= "from " . $self->q($opt{table}) . " $w->{clause} ";
    
    # Execute query
    $self->execute($sql, $w->{param}, %opt);
}

sub delete_all { shift->delete(@_, allow_delete_all => 1) }

sub DESTROY {}

sub create_model {
    my $self = shift;
    
    # Options
    my $opt = ref $_[0] eq 'HASH' ? $_[0] : {@_};
    $opt->{dbi} = $self;
    my $model_class = delete $opt->{model_class} || 'DBIx::Custom::Next::Model';
    my $model_table = delete $opt->{table};
    
    # Create model
    my $model = $model_class->new($opt);
    weaken $model->{dbi};
    $model->table($model_table) unless $model->table;
    
    # Set model
    $self->model($model->table, $model);
    
    return $self->model($model->table);
}

sub each_column {
    my ($self, $cb, %options) = @_;

    my $user_column_info = $self->user_column_info;
    
    if ($user_column_info) {
        $self->$cb($_->{table}, $_->{column}, $_->{info}) for @$user_column_info;
    }
    else {
    
        my $re = $self->exclude_table || $options{exclude_table};
        # Tables
        my %tables;
        $self->each_table(sub { $tables{$_[1]}++ });

        # Iterate all tables
        my @tables = sort keys %tables;
        for (my $i = 0; $i < @tables; $i++) {
            my $table = $tables[$i];
            
            # Iterate all columns
            my $sth_columns;
            eval {$sth_columns = $self->dbh->column_info(undef, undef, $table, '%')};
            next if $@;
            while (my $column_info = $sth_columns->fetchrow_hashref) {
                my $column = $column_info->{COLUMN_NAME};
                $self->$cb($table, $column, $column_info);
            }
        }
    }
}

sub each_table {
    my ($self, $cb, %option) = @_;
    
    my $user_table_infos = $self->user_table_info;
    
    # Iterate tables
    if ($user_table_infos) {
        $self->$cb($_->{table}, $_->{info}) for @$user_table_infos;
    }
    else {
        my $re = $self->exclude_table || $option{exclude};
        my $sth_tables = $self->dbh->table_info;
        while (my $table_info = $sth_tables->fetchrow_hashref) {
            
            # Table
            my $table = $table_info->{TABLE_NAME};
            next if defined $re && $table =~ /$re/;
            $self->$cb($table, $table_info);
        }
    }
}

sub execute {
    my ($self, $sql, $param, %opt) = @_;
    $param ||= {};

    my $tables = $opt{table} || [];
    $tables = [$tables] unless ref $tables eq 'ARRAY';
    
    # Merge second parameter
    my @cleanup;
    my $saved_param;
    if (ref $param eq 'ARRAY') {
        my $param2 = $param->[1];
        $param = $param->[0];
        for my $column (keys %$param2) {
            if (!exists $param->{$column}) {
                $param->{$column} = $param2->{$column};
                push @cleanup, $column;
            }
            else {
                delete $param->{$_} for @cleanup;
                @cleanup = ();
                $saved_param  = $param;
                $param = $self->merge_param($param, $param2);
                delete $saved_param->{$_} for (@{$opt{cleanup} || []});
                last;
            }
        }
    }
    
    # Append
    $sql .= " $opt{append}" if defined $opt{append};
    
    # Query
    my $query;
    $query = $opt{reuse}->{$sql} if $opt{reuse};
    
    if ($query) {
        # Save query
        $self->{last_sql} = $query->{sql};
    }
    else {
        
        my $safety = $self->{safety_character} || $self->safety_character;
        # Check unsafety keys
        unless ((join('', keys %$param) || '') =~ /^[$safety\.]+$/) {
            for my $column (keys %$param) {
                croak qq{"$column" is not safety column name } . _subname
                  unless $column =~ /^[$safety\.]+$/;
            }
        }

        # Query
        $query = $self->_build_query($sql);

        # After build sql
        $query->{sql} = $opt{after_build_sql}->($query->{sql})
          if $opt{after_build_sql};
            
        # Save sql
        $self->{last_sql} = $query->{sql};
        
        # Prepare statement handle
        my $sth;
        eval { $sth = $self->dbh->prepare($query->{sql}) };
        
        if ($@) {
            $self->_croak($@, qq{. Following SQL is executed.\n}
              . qq{$query->{sql}\n} . _subname);
        }
        
        # Set statement handle
        $query->{sth} = $sth;
        
        # Save query
        $opt{reuse}->{$sql} = $query if $opt{reuse};
    }

    # Return query
    if ($opt{query}) {
      delete $param->{$_} for (@cleanup, @{$opt{cleanup} || []});
      return $query;
    }
    
    # Tables
    my $main_table = @{$tables}[-1];
    
    # Type rule
    my $type_filters = {};
    my $type_rule_off = !$self->{_type_rule_is_called} || $opt{type_rule_off};
    unless ($type_rule_off) {
        my $type_rule_off_parts = {
            1 => $opt{type_rule1_off},
            2 => $opt{type_rule2_off}
        };
        for my $i (1, 2) {
            unless ($type_rule_off_parts->{$i}) {
                $type_filters->{$i} = {};
                my $table_alias = $opt{table_alias} || {};
                for my $alias (keys %$table_alias) {
                    my $table = $table_alias->{$alias};
                    
                    for my $column (keys %{$self->{"_into$i"}{key}{$table} || {}}) {
                        $type_filters->{$i}->{"$alias.$column"} = $self->{"_into$i"}{key}{$table}{$column};
                    }
                }
                $type_filters->{$i} = {%{$type_filters->{$i}}, %{$self->{"_into$i"}{key}{$main_table} || {}}}
                  if $main_table;
            }
        }
    }

    my $sth = $query->{sth};
    my $affected;
    
    # Execute
    my $bind;
    my $bind_types;
    if (!$query->{duplicate} && $type_rule_off &&
      !$opt{filter} && !$opt{bind_type} && !$ENV{DBIX_CUSTOM_DEBUG}) 
    {
        eval { $affected = $sth->execute(map { $param->{$_} } @{$query->{columns}}) };
    }
    else {
        ($bind, $bind_types) = $self->_create_bind_values($param,
           $query->{columns}, $opt{filter}, $type_filters, $opt{bind_type});
        eval {
            if ($opt{bind_type}) {
                $sth->bind_param($_ + 1, $bind->[$_],
                    $bind_types->[$_] ? $bind_types->[$_] : ())
                  for (0 .. @$bind - 1);
                $affected = $sth->execute;
            }
            else { $affected = $sth->execute(@$bind) }
        };
    }
    $self->_croak($@, qq{. Following SQL is executed.\n}
      . qq{$query->{sql}\n} . _subname) if $@;

    # Remove id from parameter
    delete $param->{$_} for (@cleanup, @{$opt{cleanup} || []});
    
    # DEBUG message
    if ($ENV{DBIX_CUSTOM_DEBUG}) {
        warn "SQL:\n" . $query->{sql} . "\n";
        my @output;
        for my $value (@$bind) {
            $value = 'undef' unless defined $value;
            $value = encode($ENV{DBIX_CUSTOM_DEBUG_ENCODING} || 'UTF-8', $value)
              if utf8::is_utf8($value);
            push @output, $value;
        }
        warn "Bind values: " . join(', ', @output) . "\n\n";
    }
    
    # Not select statement
    return $affected unless $sth->{NUM_OF_FIELDS};
    
    # Result
    return $self->result_class->new(
        sth => $sth,
        dbi => $self,
        type_rule => {
            from1 => $self->type_rule->{from1},
            from2 => $self->type_rule->{from2}
        },
    );
}

sub get_table_info {
    my ($self, %opt) = @_;
    
    my $exclude = delete $opt{exclude};
    croak qq/"$_" is wrong option/ for keys %opt;
    
    my $table_info = [];
    $self->each_table(
        sub { push @$table_info, {table => $_[1], info => $_[2] } },
        exclude => $exclude
    );
    
    return [sort {$a->{table} cmp $b->{table} } @$table_info];
}

sub get_column_info {
    my ($self, %opt) = @_;
    
    my $exclude_table = delete $opt{exclude_table};
    croak qq/"$_" is wrong option/ for keys %opt;
    
    my $column_info = [];
    $self->each_column(
        sub { push @$column_info, {table => $_[1], column => $_[2], info => $_[3] } },
        exclude_table => $exclude_table
    );
    
    return [
      sort {$a->{table} cmp $b->{table} || $a->{column} cmp $b->{column} }
        @$column_info];
}

sub helper {
    my $self = shift;
    
    # Register method
    my $methods = ref $_[0] eq 'HASH' ? $_[0] : {@_};
    $self->{_methods} = {%{$self->{_methods} || {}}, %$methods};
    
    return $self;
}

sub insert {
    my ($self, $param, %opt) = @_;
    $param ||= {};

    # Created time and updated time
    my @cleanup;
    if (defined $opt{created_at} || defined $opt{updated_at}) {
        my $now = $self->now;
        $now = $now->() if ref $now eq 'CODE';
        if (defined $opt{created_at}) {
            $param->{$opt{created_at}} = $now;
            push @cleanup, $opt{created_at};
        }
        if (defined $opt{updated_at}) {
            $param->{$opt{updated_at}} = $now;
            push @cleanup, $opt{updated_at};
        }
    }
    
    # Merge id to parameter
    my $id_param = {};
    if (defined $opt{id}) {
        croak "insert id option must be specified with primary_key option"
          unless $opt{primary_key};
        $opt{primary_key} = [$opt{primary_key}] unless ref $opt{primary_key};
        $opt{id} = [$opt{id}] unless ref $opt{id};
        for (my $i = 0; $i < @{$opt{id}}; $i++) {
           my $key = $opt{primary_key}->[$i];
           next if exists $param->{$key};
           $param->{$key} = $opt{id}->[$i];
           push @cleanup, $key;
        }
        delete $opt{id};
    }
    
    # Insert statement
    my $sql = "insert ";
    $sql .= "$opt{prefix} " if defined $opt{prefix};
    $sql .= "into " . $self->q($opt{table}) . " "
      . $self->values_clause($param, {wrap => $opt{wrap}}) . " ";
    
    # Execute query
    $opt{cleanup} = \@cleanup;
    $self->execute($sql, $param, %opt);
}

sub include_model {
    my ($self, $name_space, $model_infos) = @_;
    
    # Name space
    $name_space ||= '';
    
    # Get Model infomations
    unless ($model_infos) {

        # Load name space module
        croak qq{"$name_space" is invalid class name } . _subname
          if $name_space =~ /[^\w:]/;
        eval "use $name_space";
        croak qq{Name space module "$name_space.pm" is needed. $@ }
            . _subname
          if $@;
        
        # Search model modules
        my $path = $INC{"$name_space.pm"};
        $path =~ s/\.pm$//;
        opendir my $dh, $path
          or croak qq{Can't open directory "$path": $! } . _subname
        $model_infos = [];
        while (my $module = readdir $dh) {
            push @$model_infos, $module
              if $module =~ s/\.pm$//;
        }
        close $dh;
    }
    
    # Include models
    for my $model_info (@$model_infos) {
        
        # Load model
        my $model_class;
        my $model_table;
        if (ref $model_info eq 'HASH') {
            $model_class = $model_info->{class};
            $model_table = $model_info->{table};
            $model_table ||= $model_class;
        }
        else { $model_class = $model_table = $model_info }
        my $mclass = "${name_space}::$model_class";
        croak qq{"$mclass" is invalid class name } . _subname
          if $mclass =~ /[^\w:]/;
        unless ($mclass->can('isa')) {
            eval "use $mclass";
            croak "$@ " . _subname if $@;
        }
        
        # Create model
        my $opt = {};
        $opt->{model_class} = $mclass if $mclass;
        $opt->{table}       = $model_table if $model_table;
        $self->create_model($opt);
    }
    
    return $self;
}

sub like_value { sub { "%$_[0]%" } }

sub mapper {
    my $self = shift;
    return DBIx::Custom::Next::Mapper->new(@_);
}

sub merge_param {
    my ($self, @params) = @_;
    
    # Merge parameters
    my $merge = {};
    for my $param (@params) {
        for my $column (keys %$param) {
            my $param_is_array = ref $param->{$column} eq 'ARRAY' ? 1 : 0;
            
            if (exists $merge->{$column}) {
                $merge->{$column} = [$merge->{$column}]
                  unless ref $merge->{$column} eq 'ARRAY';
                push @{$merge->{$column}},
                  ref $param->{$column} ? @{$param->{$column}} : $param->{$column};
            }
            else {
                $merge->{$column} = $param->{$column};
            }
        }
    }
    
    return $merge;
}

sub model {
    my ($self, $name, $model) = @_;
    
    # Set model
    if ($model) {
        $self->models->{$name} = $model;
        return $self;
    }
    
    # Check model existance
    croak qq{Model "$name" is not included } . _subname
      unless $self->models->{$name};
    
    # Get model
    return $self->models->{$name};
}

sub mycolumn {
    my ($self, $table, $columns) = @_;
    
    # Create column clause
    my @column;
    $columns ||= [];
    push @column, $self->q($table) . "." . $self->q($_) .
      " as " . $self->q($_)
      for @$columns;
    
    return join (', ', @column);
}

sub new {
    my $self = shift->SUPER::new(@_);
    
    # Check attributes
    my @attrs = keys %$self;
    for my $attr (@attrs) {
        croak qq{Invalid attribute: "$attr" } . _subname
          unless $self->can($attr);
    }

    return $self;
}

sub not_exists { DBIx::Custom::Next::NotExists->singleton }

sub order {
    my $self = shift;
    return DBIx::Custom::Next::Order->new(dbi => $self, @_);
}

sub q {
    my ($self, $value, $quotemeta) = @_;
    
    my $quote = $self->{quote} || $self->quote || '';
    return "$quote$value$quote"
      if !$quotemeta && ($quote eq '`' || $quote eq '"');
    
    my $q = substr($quote, 0, 1) || '';
    my $p;
    if (defined $quote && length $quote > 1) {
        $p = substr($quote, 1, 1);
    }
    else { $p = $q }
    
    if ($quotemeta) {
        $q = quotemeta($q);
        $p = quotemeta($p);
    }
    
    return "$q$value$p";
}

sub register_filter {
    my $self = shift;
    
    # Register filter
    my $filters = ref $_[0] eq 'HASH' ? $_[0] : {@_};
    $self->filters({%{$self->filters}, %$filters});
    
    return $self;
}

sub select {
    my ($self, %opt) = @_;

    # Options
    my $tables = [$opt{table}];
    my $param = delete $opt{param} || {};
    
    # Select statement
    my $sql = 'select ';
    
    # Prefix
    $sql .= "$opt{prefix} " if defined $opt{prefix};
    
    # Column
    if (defined $opt{column}) {
        my $columns
          = ref $opt{column} eq 'ARRAY' ? $opt{column} : [$opt{column}];
        for my $column (@$columns) {
            $column = $self->column(%$column) if ref $column eq 'HASH';
            unshift @$tables, @{$self->_search_tables($column)};
            $sql .= "$column, ";
        }
        $sql =~ s/, $/ /;
    }
    else { $sql .= '* ' }
    
    # Table
    croak "select method table option must be specified " . _subname
      unless defined $tables->[-1];
    $sql .= 'from ' . $self->q($tables->[-1] || '') . ' ';
    $sql =~ s/, $/ /;

    # Add tables in parameter
    unshift @$tables,
            @{$self->_search_tables(join(' ', keys %$param) || '')};
    
    # Where
    my $w = $self->_where_clause_and_param($opt{where}, $param,
      delete $opt{id}, $opt{primary_key}, $tables->[-1]);
    
    # Add table names in where clause
    unshift @$tables, @{$self->_search_tables($w->{clause})};
    
    # Join statement
    $self->_push_join(\$sql, $opt{join}, $tables) if defined $opt{join};
    
    # Add where clause
    $sql .= "$w->{clause} ";
    
    # Execute query
    my $result = $self->execute($sql, $w->{param}, %opt);
    
    $result;
}

sub setup_model {
    my $self = shift;
    
    # Setup model
    $self->each_column(
        sub {
            my ($self, $table, $column, $column_info) = @_;
            if (my $model = $self->models->{$table}) {
                push @{$model->columns}, $column;
            }
        }
    );
    return $self;
}

sub show_datatype {
    my ($self, $table) = @_;
    croak "Table name must be specified" unless defined $table;
    print "$table\n";
    
    my $result = $self->select(table => $table, where => "'0' <> '0'");
    my $sth = $result->sth;

    my $columns = $sth->{NAME};
    my $data_types = $sth->{TYPE};
    
    for (my $i = 0; $i < @$columns; $i++) {
        my $column = $columns->[$i];
        my $data_type = lc $data_types->[$i];
        print "$column: $data_type\n";
    }
}

sub show_typename {
    my ($self, $t) = @_;
    croak "Table name must be specified" unless defined $t;
    print "$t\n";
    
    $self->each_column(sub {
        my ($self, $table, $column, $infos) = @_;
        return unless $table eq $t;
        my $typename = lc $infos->{TYPE_NAME};
        print "$column: $typename\n";
    });
    
    return $self;
}

sub show_tables {
    my $self = shift;
    
    my %tables;
    $self->each_table(sub { $tables{$_[1]}++ });
    print join("\n", sort keys %tables) . "\n";
    return $self;
}

sub type_rule {
    my $self = shift;

    $self->{_type_rule_is_called} = 1;
    
    if (@_) {
        my $type_rule = ref $_[0] eq 'HASH' ? $_[0] : {@_};
        
        # Into
        for my $i (1 .. 2) {
            my $into = "into$i";
            my $exists_into = exists $type_rule->{$into};
            $type_rule->{$into} = _array_to_hash($type_rule->{$into});
            $self->{type_rule} = $type_rule;
            $self->{"_$into"} = {};
            for my $type_name (keys %{$type_rule->{$into} || {}}) {
                croak qq{type name of $into section must be lower case}
                  if $type_name =~ /[A-Z]/;
            }
            
            $self->each_column(sub {
                my ($dbi, $table, $column, $column_info) = @_;
                
                my $type_name = lc $column_info->{TYPE_NAME};
                if ($type_rule->{$into} &&
                    (my $filter = $type_rule->{$into}->{$type_name}))
                {
                    return unless exists $type_rule->{$into}->{$type_name};
                    if  (defined $filter && ref $filter ne 'CODE') 
                    {
                        my $fname = $filter;
                        croak qq{Filter "$fname" is not registered" } . _subname
                          unless exists $self->filters->{$fname};
                        
                        $filter = $self->filters->{$fname};
                    }

                    $self->{"_$into"}{key}{$table}{$column} = $filter;
                    $self->{"_$into"}{dot}{"$table.$column"} = $filter;
                }
            });
        }

        # From
        for my $i (1 .. 2) {
            $type_rule->{"from$i"} = _array_to_hash($type_rule->{"from$i"});
            for my $data_type (keys %{$type_rule->{"from$i"} || {}}) {
                croak qq{data type of from$i section must be lower case or number}
                  if $data_type =~ /[A-Z]/;
                my $fname = $type_rule->{"from$i"}{$data_type};
                if (defined $fname && ref $fname ne 'CODE') {
                    croak qq{Filter "$fname" is not registered" } . _subname
                      unless exists $self->filters->{$fname};
                    
                    $type_rule->{"from$i"}{$data_type} = $self->filters->{$fname};
                }
            }
        }
        
        return $self;
    }
    
    return $self->{type_rule} || {};
}

sub update {
    my ($self, $param, %opt) = @_;
    $param ||= {};
    
    # Don't allow update all rows
    croak qq{update method where option must be specified } . _subname
      if !$opt{where} && !defined $opt{id} && !$opt{allow_update_all};
    
    # Created time and updated time
    my @cleanup;
    if (defined $opt{updated_at}) {
        my $now = $self->now;
        $now = $now->() if ref $now eq 'CODE';
        $param->{$opt{updated_at}} = $self->now->();
        push @cleanup, $opt{updated_at};
    }

    # Assign clause
    my $assign_clause = $self->assign_clause($param, {wrap => $opt{wrap}});
    
    # Where
    my $w = $self->_where_clause_and_param($opt{where}, {},
      delete $opt{id}, $opt{primary_key}, $opt{table});
    
    # Update statement
    my $sql = "update ";
    $sql .= "$opt{prefix} " if defined $opt{prefix};
    $sql .= $self->q($opt{table}) . " set $assign_clause $w->{clause} ";
    
    # Execute query
    $opt{cleanup} = \@cleanup;
    $self->execute($sql, [$param, $w->{param}], %opt);
}

sub update_all { shift->update(@_, allow_update_all => 1) };

sub update_or_insert {
    my ($self, $param, %opt) = @_;
    croak "update_or_insert method need primary_key and id option "
      unless defined $opt{id} && defined $opt{primary_key};
    my $statement_opt = $opt{option} || {};

    my $rows = $self->select(%opt, %{$statement_opt->{select} || {}})->all;
    if (@$rows == 0) {
        return $self->insert($param, %opt, %{$statement_opt->{insert} || {}});
    }
    elsif (@$rows == 1) {
        return $self->update($param, %opt, %{$statement_opt->{update} || {}});
    }
    else {
        croak "selected row must be one " . _subname;
    }
}

sub values_clause {
    my ($self, $param, $opts) = @_;
    
    my $wrap = $opts->{wrap} || {};
    
    # Create insert parameter
    my ($q, $p) = split //, $self->q('');
    
    # values clause(performance is important)
    '(' .
    join(
      ', ',
      map { "$q$_$p" } sort keys %$param
    ) .
    ') values (' .
    join(
      ', ',
      map {
          ref $param->{$_} eq 'SCALAR' ? ${$param->{$_}} :
          $wrap->{$_} ? $wrap->{$_}->(":$_") :
          ":$_";
      } sort keys %$param
    ) .
    ')'
}

sub where { DBIx::Custom::Next::Where->new(dbi => shift, @_) }

sub _build_query {
    my ($self, $sql) = @_;
    
    $sql ||= '';
    my $columns = [];
    my %duplicate;
    my $duplicate;
    my $c = $self->{safety_character} || $self->safety_character;
    # Parameter regex
    $sql =~ s/([0-9]):/$1\\:/g;
    while ($sql =~ /(^|.*?[^\\]):([$c\.]+)(?:\{(.*?)\})?(.*)/sg) {
        push @$columns, $2;
        $duplicate = 1 if ++$duplicate{$columns->[-1]} > 1;
        $sql = defined $3 ? "$1$2 $3 ?$4" : "$1?$4";
    }
    $sql =~ s/\\:/:/g if index($sql, "\\:") != -1;

    # Create query
    {sql => $sql, columns => $columns, duplicate => $duplicate};
}

sub _create_query {
    
    my ($self, $source, $after_build_sql) = @_;
    
    # Query
    my $query = $self->_build_query($source);

    # After build sql
    $query->{sql} = $after_build_sql->($query->{sql}) if $after_build_sql;
        
    # Save sql
    $self->{last_sql} = $query->{sql};
    
    # Prepare statement handle
    my $sth;
    eval { $sth = $self->dbh->prepare($query->{sql}) };
    
    if ($@) {
        $self->_croak($@, qq{. Following SQL is executed.\n}
          . qq{$query->{sql}\n} . _subname);
    }
    
    # Set statement handle
    $query->{sth} = $sth;
    
    return $query;
}

sub _create_bind_values {
    my ($self, $params, $columns, $filter, $type_filters, $bind_type) = @_;
    
    # Bind type
    $bind_type ||= {};
    $bind_type = _array_to_hash($bind_type) if ref $bind_type eq 'ARRAY';

    # Replace filter name to code
    $filter ||= {};
    $filter = ref $filter eq 'ARRAY' ? _array_to_hash($filter) : $filter;
    for my $column (keys %$filter) {
        my $name = $filter->{$column};
        if (!defined $name) {
            $filter->{$column} = undef;
        }
        elsif (ref $name ne 'CODE') {
          croak qq{Filter "$name" is not registered" } . _subname
            unless exists $self->filters->{$name};
          $filter->{$column} = $self->filters->{$name};
        }
    }
    
    # Create bind values
    my @bind;
    my @types;
    my %count;
    my %not_exists;
    for my $column (@$columns) {
        
        # Bind value
        if(ref $params->{$column} eq 'ARRAY') {
            my $i = $count{$column} || 0;
            $i += $not_exists{$column} || 0;
            my $found;
            for (my $k = $i; $i < @{$params->{$column}}; $k++) {
                if (ref $params->{$column}->[$k] eq 'DBIx::Custom::Next::NotExists') {
                    $not_exists{$column}++;
                }
                else  {
                    push @bind, $params->{$column}->[$k];
                    $found = 1;
                    last
                }
            }
            next unless $found;
        }
        else { push @bind, $params->{$column} }
        
        # Filter
        $bind[-1] = $filter->{$column}->($bind[-1]) if $filter->{$column};
        
        # Type rule
        if ($self->{_type_rule_is_called}) {
            my $tf1 = $self->{"_into1"}->{dot}->{$column}
              || $type_filters->{1}->{$column};
            $bind[-1] = $tf1->($bind[-1]) if $tf1;
            my $tf2 = $self->{"_into2"}->{dot}->{$column}
              || $type_filters->{2}->{$column};
            $bind[-1] = $tf2->($bind[-1]) if $tf2;
        }
       
        # Bind types
        push @types, $bind_type->{$column};
        
        # Count up 
        $count{$column}++;
    }
    
    return (\@bind, \@types);
}

sub _id_to_param {
    my ($self, $id, $primary_keys, $table) = @_;
    
    # Check primary key
    croak "primary_key option " .
          "must be specified when id option is used" . _subname
      unless defined $primary_keys;
    $primary_keys = [$primary_keys] unless ref $primary_keys eq 'ARRAY';
    
    # Create parameter
    my $param = {};
    if (defined $id) {
        $id = [$id] unless ref $id;
        for(my $i = 0; $i < @$id; $i++) {
           my $key = $primary_keys->[$i];
           $key = "$table." . $key if $table;
           $param->{$key} = $id->[$i];
        }
    }
    
    return $param;
}

sub _connect {
    my $self = shift;
    
    # Attributes
    my $dsn = $self->dsn;
    croak qq{"dsn" must be specified } . _subname
      unless $dsn;
    my $user        = $self->user;
    my $password    = $self->password;
    my $option = $self->option;
    $option = {%{$self->default_option}, %$option};
    
    # Connect
    my $dbh;
    eval {
        $dbh = DBI->connect(
            $dsn,
            $user,
            $password,
            $option
        );
    };
    
    # Connect error
    croak "$@ " . _subname if $@;
    
    return $dbh;
}

sub _croak {
    my ($self, $error, $append) = @_;
    
    # Append
    $append ||= "";
    
    # Verbose
    if ($Carp::Verbose) { croak $error }
    
    # Not verbose
    else {
        
        # Remove line and module infromation
        my $at_pos = rindex($error, ' at ');
        $error = substr($error, 0, $at_pos);
        $error =~ s/\s+$//;
        croak "$error$append";
    }
}

sub _driver { lc shift->{dbh}->{Driver}->{Name} }

sub _need_tables {
    my ($self, $tree, $need_tables, $tables) = @_;
    
    # Get needed tables
    for my $table (@$tables) {
        if ($tree->{$table}) {
            $need_tables->{$table} = 1;
            $self->_need_tables($tree, $need_tables, [$tree->{$table}{parent}])
        }
    }
}

sub _push_join {
    my ($self, $sql, $join, $join_tables) = @_;
    
    $join = [$join] unless ref $join eq 'ARRAY';
    
    # No join
    return unless @$join;
    
    # Push join clause
    my $tree = {};
    for (my $i = 0; $i < @$join; $i++) {
        
        # Arrange
        my $join_clause;;
        my $option;
        if (ref $join->[$i] eq 'HASH') {
            $join_clause = $join->[$i]->{clause};
            $option = {table => $join->[$i]->{table}};
        }
        else {
            $join_clause = $join->[$i];
            $option = {};
        };

        # Find tables in join clause
        my $table1;
        my $table2;
        if (my $table = $option->{table}) {
            $table1 = $table->[0];
            $table2 = $table->[1];
        }
        else {
            my $q = $self->quote || '';
            my $j_clause = (split /\s+on\s+/, $join_clause)[-1];
            $j_clause =~ s/'.+?'//g;
            my $q_re = quotemeta($q);
            $j_clause =~ s/[$q_re]//g;
            
            my @j_clauses = reverse split /\s(and|on)\s/, $j_clause;
            my $c = $self->safety_character;
            my $join_re = qr/($c+)\.$c+[^$c].*?($c+)\.$c+/sm;
            for my $clause (@j_clauses) {
                if ($clause =~ $join_re) {
                    $table1 = $1;
                    $table2 = $2;
                    last;
                }                
            }
        }
        croak qq{join clause must have two table name after "on" keyword. } .
              qq{"$join_clause" is passed }  . _subname
          unless defined $table1 && defined $table2;
        croak qq{right side table of "$join_clause" must be unique }
            . _subname
          if exists $tree->{$table2};
        croak qq{Same table "$table1" is specified} . _subname
          if $table1 eq $table2;
        $tree->{$table2}
          = {position => $i, parent => $table1, join => $join_clause};
    }
    
    # Search need tables
    my $need_tables = {};
    $self->_need_tables($tree, $need_tables, $join_tables);
    my @need_tables = sort { $tree->{$a}{position} <=> $tree->{$b}{position} }
      keys %$need_tables;
    
    # Add join clause
    $$sql .= $tree->{$_}{join} . ' ' for @need_tables;
}

sub _remove_duplicate_table {
    my ($self, $tables, $main_table) = @_;
    
    # Remove duplicate table
    my %tables = map {defined $_ ? ($_ => 1) : ()} @$tables;
    delete $tables{$main_table} if $main_table;
    
    my $new_tables = [keys %tables, $main_table ? $main_table : ()];
    if (my $q = $self->quote || '') {
        $q = quotemeta($q);
        $_ =~ s/[$q]//g for @$new_tables;
    }

    return $new_tables;
}

sub _search_tables {
    my ($self, $source) = @_;
    
    # Search tables
    my $tables = [];
    my $safety_character = $self->safety_character;
    my $q = $self->quote;
    my $quoted_safety_character_re = $self->q("?([$safety_character]+)", 1);
    my $table_re = $q ? qr/(?:^|[^$safety_character])${quoted_safety_character_re}?\./
                      : qr/(?:^|[^$safety_character])([$safety_character]+)\./;
    while ($source =~ /$table_re/g) {
        push @$tables, $1;
    }
    
    return $tables;
}

sub _where_clause_and_param {
    my ($self, $where, $param, $id, $primary_key, $table) = @_;

    $where ||= {};
    $where = $self->_id_to_param($id, $primary_key, $table) if defined $id;
    $param ||= {};
    my $w = {};
    my $where_clause = '';

    my $obj;
    
    if (ref $where) {
        if (ref $where eq 'HASH') {
            my $clause = ['and'];
            my $column_join = '';
            for my $column (keys %$where) {
                $column_join .= $column;
                my $table;
                my $c;
                if ($column =~ /(?:(.*?)\.)?(.*)/) {
                    $table = $1;
                    $c = $2;
                }
                
                my $table_quote;
                $table_quote = $self->q($table) if defined $table;
                my $column_quote = $self->q($c);
                $column_quote = $table_quote . '.' . $column_quote
                  if defined $table_quote;
                push @$clause, "$column_quote = :$column";
            }

            # Check unsafety column
            my $safety = $self->safety_character;
            unless ($column_join =~ /^[$safety\.]+$/) {
                for my $column (keys %$where) {
                    croak qq{"$column" is not safety column name } . _subname
                      unless $column =~ /^[$safety\.]+$/;
                }
            }
            
            $obj = $self->where(clause => $clause, param => $where);
        }
        elsif (ref $where eq 'DBIx::Custom::Next::Where') { $obj = $where }
        elsif (ref $where eq 'ARRAY') {
            $obj = $self->where(clause => $where->[0], param => $where->[1]);
        }
        
        # Check where argument
        croak qq{"where" must be hash reference or DBIx::Custom::Next::Where object}
            . qq{or array reference, which contains where clause and parameter}
            . _subname
          unless ref $obj eq 'DBIx::Custom::Next::Where';

        $w->{param} = keys %$param
                    ? $self->merge_param($param, $obj->param)
                    : $obj->param;
        $w->{clause} = $obj->to_string;
    }
    elsif ($where) {
        $w->{clause} = "where $where";
        $w->{param} = $param;
    }
    
    return $w;
}

1;

=head1 NAME

DBIx::Custom::Next - DBI extension to execute insert, update, delete, and select easily

=head1 SYNOPSIS

    use DBIx::Custom::Next;
    
    # Connect
    my $dbi = DBIx::Custom::Next->connect(
        dsn => "dbi:mysql:database=dbname",
        user => 'ken',
        password => '!LFKD%$&',
        option => {mysql_enable_utf8 => 1}
    );

    # Insert 
    $dbi->insert({title => 'Perl', author => 'Ken'}, table  => 'book');
    
    # Update 
    $dbi->update({title => 'Perl', author => 'Ken'}, table  => 'book',
      where  => {id => 5});
    
    # Delete
    $dbi->delete(table  => 'book', where => {author => 'Ken'});

    # Select
    my $result = $dbi->select(table  => 'book',
      column => ['title', 'author'], where  => {author => 'Ken'});

    # Select, more complex
    my $result = $dbi->select(
        table  => 'book',
        column => [
            {book => [qw/title author/]},
            {company => ['name']}
        ],
        where  => {'book.author' => 'Ken'},
        join => ['left outer join company on book.company_id = company.id'],
        append => 'order by id limit 5'
    );
    
    # Fetch
    while (my $row = $result->fetch) {
        
    }
    
    # Fetch as hash
    while (my $row = $result->fetch_hash) {
        
    }
    
    # Execute SQL with parameter.
    $dbi->execute(
        "select id from book where author = :author and title like :title",
        {author => 'ken', title => '%Perl%'}
    );
    
=head1 DESCRIPTION

L<DBIx::Custom::Next> is L<DBI> wrapper module to execute SQL easily.
This module have the following features.

=over 4

=item *

Execute C<insert>, C<update>, C<delete>, or C<select> statement easily

=item *

Create C<where> clause flexibly

=item *

Named place holder support

=item *

Model support

=item *

Connection manager support

=item *

Choice your favorite relational database management system,
C<MySQL>, C<SQLite>, C<PostgreSQL>, C<Oracle>,
C<Microsoft SQL Server>, C<Microsoft Access>, C<DB2> or anything, 

=item *

Filtering by data type or column name

=item *

Create C<order by> clause flexibly

=back

=head1 DOCUMENTATION

L<DBIx::Custom::Next::Guide> - How to use L<DBIx::Custom::Next>

L<DBIx::Custom::Next Wiki|https://github.com/yuki-kimoto/DBIx-Custom/wiki>
- Theare are various examples.

Module documentations - 
L<DBIx::Custom::Next::Result>,
L<DBIx::Custom::Next::Query>,
L<DBIx::Custom::Next::Where>,
L<DBIx::Custom::Next::Model>,
L<DBIx::Custom::Next::Order>

=head1 ATTRIBUTES

=head2 C<connector>

    my $connector = $dbi->connector;
    $dbi = $dbi->connector($connector);

Connection manager object. if C<connector> is set, you can get C<dbh>
through connection manager. Conection manager object must have C<dbh> mehtod.

This is L<DBIx::Connector> example. Please pass
C<default_option> to L<DBIx::Connector> C<new> method.

    my $connector = DBIx::Connector->new(
        "dbi:mysql:database=$database",
        $user,
        $password,
        DBIx::Custom::Next->new->default_option
    );
    
    my $dbi = DBIx::Custom::Next->connect(connector => $connector);

If C<connector> is set to 1 when connect method is called,
L<DBIx::Connector> is automatically set to C<connector>

    my $dbi = DBIx::Custom::Next->connect(
      dsn => $dsn, user => $user, password => $password, connector => 1);
    
    my $connector = $dbi->connector; # DBIx::Connector

Note that L<DBIx::Connector> must be installed.

=head2 C<dsn>

    my $dsn = $dbi->dsn;
    $dbi = $dbi->dsn("DBI:mysql:database=dbname");

Data source name, used when C<connect> method is executed.

=head2 C<default_option>

    my $default_option = $dbi->default_option;
    $dbi = $dbi->default_option($default_option);

L<DBI> default option, used when C<connect> method is executed,
default to the following values.

    {
        RaiseError => 1,
        PrintError => 0,
        AutoCommit => 1,
    }

=head2 C<exclude_table>

    my $exclude_table = $dbi->exclude_table;
    $dbi = $dbi->exclude_table(qr/pg_/);

Excluded table regex.
C<each_column>, C<each_table>, C<type_rule>,
and C<setup_model> methods ignore matching tables.

=head2 C<filters>

    my $filters = $dbi->filters;
    $dbi = $dbi->filters(\%filters);

Filters, registered by C<register_filter> method.

=head2 C<last_sql>

    my $last_sql = $dbi->last_sql;
    $dbi = $dbi->last_sql($last_sql);

Get last successed SQL executed by C<execute> method.

=head2 C<now>

    my $now = $dbi->now;
    $dbi = $dbi->now($now);

Code reference which return current time, default to the following code reference.

    sub {
        my ($sec, $min, $hour, $mday, $mon, $year) = localtime;
        $mon++;
        $year += 1900;
        return sprintf("%04d-%02d-%02d %02d:%02d:%02d");
    }

This return the time like C<2011-10-14 05:05:27>.

This is used by C<insert> method's C<created_at> option and C<updated_at> option,
and C<update> method's C<updated_at> option.

=head2 C<models>

    my $models = $dbi->models;
    $dbi = $dbi->models(\%models);

Models, included by C<include_model> method.

=head2 C<option>

    my $option = $dbi->option;
    $dbi = $dbi->option($option);

L<DBI> option, used when C<connect> method is executed.
Each value in option override the value of C<default_option>.

=head2 C<password>

    my $password = $dbi->password;
    $dbi = $dbi->password('lkj&le`@s');

Password, used when C<connect> method is executed.

=head2 C<quote>

     my quote = $dbi->quote;
     $dbi = $dbi->quote('"');

Reserved word quote.
Default to double quote '"' except for mysql.
In mysql, default to back quote '`'

You can set quote pair.

    $dbi->quote('[]');

=head2 C<result_class>

    my $result_class = $dbi->result_class;
    $dbi = $dbi->result_class('DBIx::Custom::Next::Result');

Result class, default to L<DBIx::Custom::Next::Result>.

=head2 C<safety_character>

    my $safety_character = $dbi->safety_character;
    $dbi = $dbi->safety_character($character);

Regex of safety character for table and column name, default to '\w'.
Note that you don't have to specify like '[\w]'.

=head2 C<separator>

    my $separator = $dbi->separator;
    $dbi = $dbi->separator('-');

Separator which join table name and column name.
This have effect to C<column> and C<mycolumn> method,
and C<select> method's column option.

Default to C<.>.

=head2 C<user>

    my $user = $dbi->user;
    $dbi = $dbi->user('Ken');

User name, used when C<connect> method is executed.

=head2 C<user_column_info>

    my $user_column_info = $dbi->user_column_info;
    $dbi = $dbi->user_column_info($user_column_info);

You can set the date like the following one.

    [
        {table => 'book', column => 'title', info => {...}},
        {table => 'author', column => 'name', info => {...}}
    ]

Usually, you set return value of C<get_column_info>.

    my $user_column_info
      = $dbi->get_column_info(exclude_table => qr/^system/);
    $dbi->user_column_info($user_column_info);

If C<user_column_info> is set, C<each_column> use C<user_column_info>
to find column info. this is very fast.

=head2 C<user_table_info>

    my $user_table_info = $dbi->user_table_info;
    $dbi = $dbi->user_table_info($user_table_info);

You can set the following data.

    [
        {table => 'book', info => {...}},
        {table => 'author', info => {...}}
    ]

Usually, you can set return value of C<get_table_info>.

    my $user_table_info = $dbi->get_table_info(exclude => qr/^system/);
    $dbi->user_table_info($user_table_info);

If C<user_table_info> is set, C<each_table> use C<user_table_info>
to find table info.

=head1 METHODS

L<DBIx::Custom::Next> inherits all methods from L<Object::Simple>
and use all methods of L<DBI>
and implements the following new ones.

=head2 C<available_datatype>

    print $dbi->available_datatype;

Get available data types. You can use these data types
in C<type rule>'s C<from1> and C<from2> section.

=head2 C<available_typename>

    print $dbi->available_typename;

Get available type names. You can use these type names in
C<type_rule>'s C<into1> and C<into2> section.

=head2 C<assign_clause>

    my $assign_clause = $dbi->assign_clause({title => 'a', age => 2});

Create assign clause

    title = :title, author = :author

This is used to create update clause.

    "update book set " . $dbi->assign_clause({title => 'a', age => 2});

=head2 C<column>

    my $column = $dbi->column(book => ['author', 'title']);

Create column clause. The follwoing column clause is created.

    book.author as "book.author",
    book.title as "book.title"

You can change separator by C<separator> attribute.

    # Separator is hyphen
    $dbi->separator('-');
    
    book.author as "book-author",
    book.title as "book-title"
    
=head2 C<connect>

    my $dbi = DBIx::Custom::Next->connect(
        dsn => "dbi:mysql:database=dbname",
        user => 'ken',
        password => '!LFKD%$&',
        option => {mysql_enable_utf8 => 1}
    );

Connect to the database and create a new L<DBIx::Custom::Next> object.

L<DBIx::Custom::Next> is a wrapper of L<DBI>.
C<AutoCommit> and C<RaiseError> options are true, 
and C<PrintError> option is false by default.

=head2 C<count>

    my $count = $dbi->count(table => 'book');

Get rows count.

Options is same as C<select> method's ones.

=head2 C<create_model>

    my $model = $dbi->create_model(
        table => 'book',
        primary_key => 'id',
        join => [
            'inner join company on book.comparny_id = company.id'
        ],
    );

Create L<DBIx::Custom::Next::Model> object and initialize model.
the module is also used from C<model> method.

   $dbi->model('book')->select(...);

=head2 C<dbh>

    my $dbh = $dbi->dbh;

Get L<DBI> database handle. if C<connector> is set, you can get
database handle through C<connector> object.

=head2 C<delete>

    $dbi->delete(table => 'book', where => {title => 'Perl'});

Execute delete statement.

The following opitons are available.

B<OPTIONS>

C<delete> method use all of C<execute> method's options,
and use the following new ones.

=over 4

=item C<id>

    id => 4
    id => [4, 5]

ID corresponding to C<primary_key>.
You can delete rows by C<id> and C<primary_key>.

    $dbi->delete(
        primary_key => ['id1', 'id2'],
        id => [4, 5],
        table => 'book',
    );

The above is same as the followin one.

    $dbi->delete(where => {id1 => 4, id2 => 5}, table => 'book');

=item C<prefix>

    prefix => 'some'

prefix before table name section.

    delete some from book

=item C<table>

    table => 'book'

Table name.

=item C<where>

Same as C<select> method's C<where> option.

=back

=head2 C<delete_all>

    $dbi->delete_all(table => $table);

Execute delete statement for all rows.
Options is same as C<delete>.

=head2 C<each_column>

    $dbi->each_column(
        sub {
            my ($dbi, $table, $column, $column_info) = @_;
            
            my $type = $column_info->{TYPE_NAME};
            
            if ($type eq 'DATE') {
                # ...
            }
        }
    );

Iterate all column informations in database.
Argument is callback which is executed when one column is found.
Callback receive four arguments. C<DBIx::Custom::Next object>, C<table name>,
C<column name>, and C<column information>.

If C<user_column_info> is set, C<each_column> method use C<user_column_info>
infromation, you can improve the performance of C<each_column> in
the following way.

    my $column_infos = $dbi->get_column_info(exclude_table => qr/^system_/);
    $dbi->user_column_info($column_info);
    $dbi->each_column(sub { ... });

=head2 C<each_table>

    $dbi->each_table(
        sub {
            my ($dbi, $table, $table_info) = @_;
            
            my $table_name = $table_info->{TABLE_NAME};
        }
    );

Iterate all table informationsfrom in database.
Argument is callback which is executed when one table is found.
Callback receive three arguments, C<DBIx::Custom::Next object>, C<table name>,
C<table information>.

If C<user_table_info> is set, C<each_table> method use C<user_table_info>
infromation, you can improve the performance of C<each_table> in
the following way.

    my $table_infos = $dbi->get_table_info(exclude => qr/^system_/);
    $dbi->user_table_info($table_info);
    $dbi->each_table(sub { ... });

=head2 C<execute>

    my $result = $dbi->execute(
      "select * from book where title = :title and author like :author",
      {title => 'Perl', author => '%Ken%'}
    );

    my $result = $dbi->execute(
      "select * from book where title = :book.title and author like :book.author",
      {'book.title' => 'Perl', 'book.author' => '%Ken%'}
    );

Execute SQL. SQL can contain column parameter such as :author and :title.
You can append table name to column name such as :book.title and :book.author.
Second argunet is data, embedded into column parameter.
Return value is L<DBIx::Custom::Next::Result> object when select statement is executed,
or the count of affected rows when insert, update, delete statement is executed.

Named placeholder such as C<:title> is replaced by placeholder C<?>.
    
    # Original
    select * from book where title = :title and author like :author
    
    # Replaced
    select * from where title = ? and author like ?;

You can specify operator with named placeholder
by C<name{operator}> syntax.

    # Original
    select * from book where :title{=} and :author{like}
    
    # Replaced
    select * from where title = ? and author like ?;

Note that colons in time format such as 12:13:15 is exeption,
it is not parsed as named placeholder.
If you want to use colon generally, you must escape it by C<\\>

    select * from where title = "aa\\:bb";

B<OPTIONS>

The following opitons are available.

=over 4

=item C<after_build_sql> 

You can filter sql after the sql is build.

    after_build_sql => $code_ref

The following one is one example.

    $dbi->select(
        table => 'book',
        column => 'distinct(name)',
        after_build_sql => sub {
            "select count(*) from ($_[0]) as t1"
        }
    );

The following SQL is executed.

    select count(*) from (select distinct(name) from book) as t1;

=item C<append>

    append => 'order by name'

Append some statement after SQL.

=item C<bind_type>

Specify database bind data type.

    bind_type => [image => DBI::SQL_BLOB]
    bind_type => [[qw/image audio/] => DBI::SQL_BLOB]

This is used to bind parameter by C<bind_param> of statment handle.

    $sth->bind_param($pos, $value, DBI::SQL_BLOB);

=item C<filter>
    
    filter => {
        title  => sub { uc $_[0] }
        author => sub { uc $_[0] }
    }

    # Filter name
    filter => {
        title  => 'upper_case',
        author => 'upper_case'
    }
        
    # At once
    filter => [
        [qw/title author/]  => sub { uc $_[0] }
    ]

Filter. You can set subroutine or filter name
registered by by C<register_filter>.
This filter is executed before data is saved into database.
and before type rule filter is executed.

=item C<query>

    query => 1

C<execute> method return L<DBIx::Custom::Next::Query> object, not executing SQL.
You can check SQL, column, or get statment handle.

    my $sql = $query->{sql};
    my $sth = $query->{sth};
    my $columns = $query->{columns};
    
=item C<reuse>
    
    reuse => $hash_ref

Reuse query object if the hash reference variable is set.
    
    my $queries = {};
    $dbi->execute($sql, $param, reuse => $queries);

This will improved performance when you want to execute same query repeatedly
because generally creating query object is slow.

=item C<primary_key>

    primary_key => 'id'
    primary_key => ['id1', 'id2']

Priamry key. This is used for C<id> option.

=item C<table>
    
    table => 'author'

If you want to omit table name in column name
and enable C<into1> and C<into2> type filter,
You must set C<table> option.

    $dbi->execute("select * from book where title = :title and author = :author",
        {title => 'Perl', author => 'Ken', table => 'book');

    # Same
    $dbi->execute(
      "select * from book where title = :book.title and author = :book.author",
      {title => 'Perl', author => 'Ken');

=item C<table_alias>

    table_alias => {user => 'worker'}

Table alias. Key is real table name, value is alias table name.
If you set C<table_alias>, you can enable C<into1> and C<into2> type rule
on alias table name.

=item C<type_rule_off>

    type_rule_off => 1

Turn C<into1> and C<into2> type rule off.

=item C<type_rule1_off>

    type_rule1_off => 1

Turn C<into1> type rule off.

=item C<type_rule2_off>

    type_rule2_off => 1

Turn C<into2> type rule off.

=back

=head2 C<get_column_info>

    my $column_infos = $dbi->get_column_info(exclude_table => qr/^system_/);

get column infomation except for one which match C<exclude_table> pattern.

    [
        {table => 'book', column => 'title', info => {...}},
        {table => 'author', column => 'name' info => {...}}
    ]

=head2 C<get_table_info>

    my $table_infos = $dbi->get_table_info(exclude => qr/^system_/);

get table infomation except for one which match C<exclude> pattern.

    [
        {table => 'book', info => {...}},
        {table => 'author', info => {...}}
    ]

You can set this value to C<user_table_info>.

=head2 C<helper>

    $dbi->helper(
        find_or_create   => sub {
            my $self = shift;
            
            # Process
        },
        ...
    );

Register helper. These helper is called directly from L<DBIx::Custom::Next> object.

    $dbi->find_or_create;

=head2 C<insert>

    $dbi->insert({title => 'Perl', author => 'Ken'}, table  => 'book');

Execute insert statement. First argument is row data. Return value is
affected row count.

If you want to set constant value to row data, use scalar reference
as parameter value.

    {date => \"NOW()"}

B<options>

C<insert> method use all of C<execute> method's options,
and use the following new ones.

=over 4

=item C<created_at>

    created_at => 'created_datetime'

Created timestamp column name. time when row is created is set to the column.
default time format is "YYYY-mm-dd HH:MM:SS", which can be changed by
C<now> attribute.

=item C<id>

    id => 4
    id => [4, 5]

ID corresponding to C<primary_key>.
You can insert a row by C<id> and C<primary_key>.

    $dbi->insert(
        {title => 'Perl', author => 'Ken'}
        primary_key => ['id1', 'id2'],
        id => [4, 5],
        table => 'book'
    );

The above is same as the followin one.

    $dbi->insert(
        {id1 => 4, id2 => 5, title => 'Perl', author => 'Ken'},
        table => 'book'
    );

=item C<prefix>

    prefix => 'or replace'

prefix before table name section

    insert or replace into book

=item C<table>

    table => 'book'

Table name.

=item C<updated_at>

This option is same as C<update> method C<updated_at> option.

=item C<wrap>

    wrap => {price => sub { "max($_[0])" }}

placeholder wrapped string.

If the following statement

    $dbi->insert({price => 100}, table => 'book',
      {price => sub { "$_[0] + 5" }});

is executed, the following SQL is executed.

    insert into book price values ( ? + 5 );

=back

=over 4

=head2 C<include_model>

    $dbi->include_model('MyModel');

Include models from specified namespace,
the following layout is needed to include models.

    lib / MyModel.pm
        / MyModel / book.pm
                  / company.pm

Name space module, extending L<DBIx::Custom::Next::Model>.

B<MyModel.pm>

    package MyModel;
    use DBIx::Custom::Next::Model -base;
    
    1;

Model modules, extending name space module.

B<MyModel/book.pm>

    package MyModel::book;
    use MyModel -base;
    
    1;

B<MyModel/company.pm>

    package MyModel::company;
    use MyModel -base;
    
    1;
    
MyModel::book and MyModel::company is included by C<include_model>.

You can get model object by C<model>.

    my $book_model = $dbi->model('book');
    my $company_model = $dbi->model('company');

See L<DBIx::Custom::Next::Model> to know model features.

=head2 C<like_value>

    my $like_value = $dbi->like_value

Code reference which return a value for the like value.

    sub { "%$_[0]%" }

=head2 C<mapper>

    my $mapper = $dbi->mapper(param => $param);

Create a new L<DBIx::Custom::Next::Mapper> object.

=head2 C<merge_param>

    my $param = $dbi->merge_param({key1 => 1}, {key1 => 1, key2 => 2});

Merge parameters. The following new parameter is created.

    {key1 => [1, 1], key2 => 2}

If same keys contains, the value is converted to array reference.

=head2 C<model>

    my $model = $dbi->model('book');

Get a L<DBIx::Custom::Next::Model> object
create by C<create_model> or C<include_model>

=head2 C<mycolumn>

    my $column = $dbi->mycolumn(book => ['author', 'title']);

Create column clause for myself. The follwoing column clause is created.

    book.author as author,
    book.title as title

=head2 C<new>

    my $dbi = DBIx::Custom::Next->new(
        dsn => "dbi:mysql:database=dbname",
        user => 'ken',
        password => '!LFKD%$&',
        option => {mysql_enable_utf8 => 1}
    );

Create a new L<DBIx::Custom::Next> object.

=head2 C<not_exists>

    my $not_exists = $dbi->not_exists;

DBIx::Custom::Next::NotExists object, indicating the column is not exists.
This is used in C<param> of L<DBIx::Custom::Next::Where> .

=head2 C<order>

    my $order = $dbi->order;

Create a new L<DBIx::Custom::Next::Order> object.

=head2 C<q>

    my $quooted = $dbi->q("title");

Quote string by value of C<quote>.

=head2 C<register_filter>

    $dbi->register_filter(
        # Time::Piece object to database DATE format
        tp_to_date => sub {
            my $tp = shift;
            return $tp->strftime('%Y-%m-%d');
        },
        # database DATE format to Time::Piece object
        date_to_tp => sub {
           my $date = shift;
           return Time::Piece->strptime($date, '%Y-%m-%d');
        }
    );
    
Register filters, used by C<filter> option of many methods.

=head2 C<select>

    my $result = $dbi->select(
        table  => 'book',
        column => ['author', 'title'],
        where  => {author => 'Ken'},
    );
    
Execute select statement.

B<OPTIONS>

C<select> method use all of C<execute> method's options,
and use the following new ones.

=over 4

=item C<column>
    
    column => 'author'
    column => ['author', 'title']

Column clause.
    
if C<column> is not specified, '*' is set.

    column => '*'

You can specify hash of array reference.

    column => [
        {book => [qw/author title/]},
        {person => [qw/name age/]}
    ]

This is expanded to the following one by using C<colomn> method.

    book.author as "book.author",
    book.title as "book.title",
    person.name as "person.name",
    person.age as "person.age"

You can specify array of array reference, first argument is
column name, second argument is alias.

    column => [
        ['date(book.register_datetime)' => 'book.register_date']
    ];

Alias is quoted properly and joined.

    date(book.register_datetime) as "book.register_date"

=item C<id>

    id => 4
    id => [4, 5]

ID corresponding to C<primary_key>.
You can select rows by C<id> and C<primary_key>.

    $dbi->select(
        primary_key => ['id1', 'id2'],
        id => [4, 5],
        table => 'book'
    );

The above is same as the followin one.

    $dbi->select(
        where => {id1 => 4, id2 => 5},
        table => 'book'
    );
    
=item C<param>

    param => {'table2.key3' => 5}

Parameter shown before where clause.
    
For example, if you want to contain tag in join clause, 
you can pass parameter by C<param> option.

    join  => ['inner join (select * from table2 where table2.key3 = :table2.key3)' . 
              ' as table2 on table1.key1 = table2.key1']

=itme C<prefix>

    prefix => 'SQL_CALC_FOUND_ROWS'

Prefix of column cluase

    select SQL_CALC_FOUND_ROWS title, author from book;

=item C<join>

    join => [
        'left outer join company on book.company_id = company_id',
        'left outer join location on company.location_id = location.id'
    ]
        
Join clause. If column cluase or where clause contain table name like "company.name",
join clausees needed when SQL is created is used automatically.

    $dbi->select(
        table => 'book',
        column => ['company.location_id as location_id'],
        where => {'company.name' => 'Orange'},
        join => [
            'left outer join company on book.company_id = company.id',
            'left outer join location on company.location_id = location.id'
        ]
    );

In above select, column and where clause contain "company" table,
the following SQL is created

    select company.location_id as location_id
    from book
      left outer join company on book.company_id = company.id
    where company.name = ?;

You can specify two table by yourself. This is useful when join parser can't parse
the join clause correctly.

    $dbi->select(
        table => 'book',
        column => ['company.location_id as location_id'],
        where => {'company.name' => 'Orange'},
        join => [
            {
                clause => 'left outer join location on company.location_id = location.id',
                table => ['company', 'location']
            }
        ]
    );

=item C<table>

    table => 'book'

Table name.

=item C<where>
    
    # Hash refrence
    where => {author => 'Ken', 'title' => 'Perl'}
    
    # DBIx::Custom::Next::Where object
    where => $dbi->where(
        clause => ['and', ':author{=}', ':title{like}'],
        param  => {author => 'Ken', title => '%Perl%'}
    );
    
    # Array reference, this is same as above
    where => [
        ['and', ':author{=}', ':title{like}'],
        {author => 'Ken', title => '%Perl%'}
    ];
    
    # String
    where => 'title is null'

Where clause. See L<DBIx::Custom::Next::Where>.
    
=back

=head2 C<setup_model>

    $dbi->setup_model;

Setup all model objects.
C<columns> of model object is automatically set, parsing database information.

=head2 C<type_rule>

    $dbi->type_rule(
        into1 => {
            date => sub { ... },
            datetime => sub { ... }
        },
        into2 => {
            date => sub { ... },
            datetime => sub { ... }
        },
        from1 => {
            # DATE
            9 => sub { ... },
            # DATETIME or TIMESTAMP
            11 => sub { ... },
        }
        from2 => {
            # DATE
            9 => sub { ... },
            # DATETIME or TIMESTAMP
            11 => sub { ... },
        }
    );

Filtering rule when data is send into and get from database.
This has a little complex problem.

In C<into1> and C<into2> you can specify
type name as same as type name defined
by create table, such as C<DATETIME> or C<DATE>.

Note that type name and data type don't contain upper case.
If these contain upper case charactor, you convert it to lower case.

C<into2> is executed after C<into1>.

Type rule of C<into1> and C<into2> is enabled on the following
column name.

=over 4

=item 1. column name

    issue_date
    issue_datetime

This need C<table> option in each method.

=item 2. table name and column name, separator is dot

    book.issue_date
    book.issue_datetime

=back

You get all type name used in database by C<available_typename>.

    print $dbi->available_typename;

In C<from1> and C<from2> you specify data type, not type name.
C<from2> is executed after C<from1>.
You get all data type by C<available_datatype>.

    print $dbi->available_datatype;

You can also specify multiple types at once.

    $dbi->type_rule(
        into1 => [
            [qw/DATE DATETIME/] => sub { ... },
        ],
    );

=head2 C<update>

    $dbi->update({title => 'Perl'}, table  => 'book', where  => {id => 4});

Execute update statement. First argument is update row data.

If you want to set constant value to row data, use scalar reference
as parameter value.

    {date => \"NOW()"}

B<OPTIONS>

C<update> method use all of C<execute> method's options,
and use the following new ones.

=over 4

=item C<id>

    id => 4
    id => [4, 5]

ID corresponding to C<primary_key>.
You can update rows by C<id> and C<primary_key>.

    $dbi->update(
        {title => 'Perl', author => 'Ken'}
        primary_key => ['id1', 'id2'],
        id => [4, 5],
        table => 'book'
    );

The above is same as the followin one.

    $dbi->update(
        {title => 'Perl', author => 'Ken'}
        where => {id1 => 4, id2 => 5},
        table => 'book'
    );

=item C<prefix>

    prefix => 'or replace'

prefix before table name section

    update or replace book

=item C<table>

    table => 'book'

Table name.

=item C<where>

Same as C<select> method's C<where> option.

=item C<wrap>

    wrap => {price => sub { "max($_[0])" }}

placeholder wrapped string.

If the following statement

    $dbi->update({price => 100}, table => 'book',
      {price => sub { "$_[0] + 5" }});

is executed, the following SQL is executed.

    update book set price =  ? + 5;

=item C<updated_at>

    updated_at => 'updated_datetime'

Updated timestamp column name. time when row is updated is set to the column.
default time format is C<YYYY-mm-dd HH:MM:SS>, which can be changed by
C<now> attribute.

=back

=head2 C<update_all>

    $dbi->update_all({title => 'Perl'}, table => 'book', );

Execute update statement for all rows.
Options is same as C<update> method.

=head2 C<update_or_insert>
    
    # ID
    $dbi->update_or_insert(
        {title => 'Perl'},
        table => 'book',
        id => 1,
        primary_key => 'id',
        option => {
            select => {
                 append => 'for update'
            }
        }
    );

Update or insert.

C<update_or_insert> method execute C<select> method first to find row.
If the row is exists, C<update> is executed.
If not, C<insert> is executed.

C<OPTIONS>

C<update_or_insert> method use all common option
in C<select>, C<update>, C<delete>, and has the following new ones.

=over 4

=item C<option>

    option => {
        select => {
            append => '...'
        },
        insert => {
            prefix => '...'
        },
        update => {
            filter => {}
        }
    }

If you want to pass option to each method,
you can use C<option> option.

=over 4

=item C<select_option>

    select_option => {append => 'for update'}

select method option,
select method is used to check the row is already exists.

=head2 C<show_datatype>

    $dbi->show_datatype($table);

Show data type of the columns of specified table.

    book
    title: 5
    issue_date: 91

This data type is used in C<type_rule>'s C<from1> and C<from2>.

=head2 C<show_tables>

    $dbi->show_tables;

Show tables.

=head2 C<show_typename>

    $dbi->show_typename($table);

Show type name of the columns of specified table.

    book
    title: varchar
    issue_date: date

This type name is used in C<type_rule>'s C<into1> and C<into2>.

=head2 C<values_clause>

    my $values_clause = $dbi->values_clause({title => 'a', age => 2});

Create values clause.

    (title, author) values (title = :title, age = :age);

You can use this in insert statement.

    my $insert_sql = "insert into book $values_clause";

=head2 C<where>

    my $where = $dbi->where(
        clause => ['and', 'title = :title', 'author = :author'],
        param => {title => 'Perl', author => 'Ken'}
    );

Create a new L<DBIx::Custom::Next::Where> object.

=head1 ENVIRONMENTAL VARIABLES

=head2 C<DBIX_CUSTOM_DEBUG>

If environment variable C<DBIX_CUSTOM_DEBUG> is set to true,
executed SQL and bind values are printed to STDERR.

=head2 C<DBIX_CUSTOM_DEBUG_ENCODING>

DEBUG output encoding. Default to UTF-8.

=head1 BUGS

Please tell me bugs if found.

C<< <kimoto.yuki at gmail.com> >>

L<http://github.com/yuki-kimoto/DBIx-Custom>

=head1 AUTHOR

Yuki Kimoto, C<< <kimoto.yuki at gmail.com> >>

=head1 COPYRIGHT & LICENSE

Copyright 2009-2011 Yuki Kimoto, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut