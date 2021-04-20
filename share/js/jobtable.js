t2hui.jobtable = {};

t2hui.jobtable.build_table = function() {
    var columns = [
        { 'name': 'tools', 'label': 'tools', 'class': 'tools', 'builder': t2hui.jobtable.tool_builder },

        { 'name': 'try', 'label': 'T', 'class': 'count', 'builder': t2hui.jobtable.build_try },

        { 'name': 'pass_count',  'label': 'P', 'class': 'count', 'builder': t2hui.jobtable.build_pass },
        { 'name': 'fail_count',  'label': 'F', 'class': 'count', 'builder': t2hui.jobtable.build_fail },

        { 'name': 'exit',  'label': 'exit',  'class': 'exit', 'builder': t2hui.jobtable.build_exit },

        { 'name': 'name', 'label': 'file/job name', 'class': 'job_name', 'builder': t2hui.jobtable.build_name },
    ];

    var table = new FieldTable({
        'class': 'job_table',
        'id': 'jobs',

        'updatable': true,

        'init': t2hui.jobtable.init_table,

        'modify_row_hook': t2hui.jobtable.modify_row,
        'place_row': t2hui.jobtable.place_row,

        'dynamic_field_attribute': 'fields',
        'dynamic_field_fetch': t2hui.jobtable.field_fetch,
        'dynamic_field_builder': t2hui.jobtable.field_builder,

        'columns': columns,
    });

    return table;
};

t2hui.jobtable.build_pass = function(item, col, data) {
    var val = item.pass_count || '0';
    col.text(val);
    col.addClass('count');
};

t2hui.jobtable.build_fail = function(item, col, data) {
    var val = item.fail_count || '0';
    col.text(val);
    col.addClass('count');
};

t2hui.jobtable.build_try = function(item, col, data) {
    var val = item.job_try || '0';
    col.text(val);
    col.addClass('count');
};

t2hui.jobtable.build_exit = function(item, col, data) {
    var val = item.exit_code != null ? item.exit_code : 'N/A';
    col.text(val);
};

t2hui.jobtable.build_name = function(item, col, data) {
    var shrt = item.shortest_file || item.name;
    var lng  = item.file || item.name;

    var tt = t2hui.build_tooltip(col.parent(), lng);
    var tooltable = $('<table class="tool_table"></table>');
    var toolrow = $('<tr></tr>');
    tooltable.append(toolrow);

    var toolcol = $('<td></td>');
    toolcol.append(tt);

    var textcol = $('<td>' + shrt + '</td>');

    toolrow.append(toolcol, textcol);

    col.append(tooltable);
};

t2hui.jobtable.tool_builder = function(item, tools, data) {
    var params = $('<div class="tool etoggle" title="See Job Parameters"><img src="/img/data.png" /></div>');
    tools.append(params);
    params.click(function() {
        $('#modal_body').empty();
        $('#modal_body').text("loading...");
        $('#free_modal').slideDown();

        var uri = base_uri + 'job/' + item.job_key;

        $.ajax(uri, {
            'data': { 'content-type': 'application/json' },
            'success': function(job) {
                var formatter = new JSONFormatter(job.parameters, 2);
                $('#modal_body').html(formatter.render());
            },
        });
    });

    var link = base_uri + 'view/' + item.run_id + '/' + item.job_key;
    var go = $('<a class="tool etoggle" title="Open Job" href="' + link + '"><img src="/img/goto.png" /></a>');
    tools.append(go);
};

t2hui.jobtable.modify_row = function(row, item) {
    if (item.short_file) {
        if (item.retry == true) {
            row.addClass('iffy_set');
            row.addClass('retry_txt');
        }
        else if (item.status == 'canceled') {
            row.addClass('iffy_set');
        }
        else if (item.status == 'pending') {
            row.addClass('pending_set');
        }
        else if (item.status == 'running') {
            row.addClass('running_set');
            if (item.fail_count > 0) {
                row.addClass('error_set');
            }
        }
        else if (item.fail == true) {
            row.addClass('error_set');
        }
        else {
            row.addClass('success_set');
        }
    }
};

t2hui.jobtable.field_builder = function(data, name) {
    var it;
    data.fields.forEach(function(field) {
        if (field.name === name) {
            it = field.data;
            return false;
        }
    });

    return it;
};

t2hui.jobtable.field_fetch = function(field_data, item) {
    return base_uri + 'job/' + item.job_key;
};

t2hui.jobtable.init_table = function(table, state) {
    var body = state['body'];

    state['fail'] = $('<span class="job_index fail"></span>');
    body.append(state['fail']);

    state['running'] = $('<span class="job_index running"></span>');
    body.append(state['running']);

    state['other'] = $('<span class="job_index other"></span>');
    body.append(state['other']);

    state['pending'] = $('<span class="job_index pending"></span>');
    body.append(state['pending']);

    state['retry'] = $('<span class="job_index retry"></span>');
    body.append(state['retry']);
}

t2hui.jobtable.place_row = function(row, item, table, state, existing) {
    if (!item.short_file) {
        state['header'].after(row);
        return true;
    }

    if (item.retry) {
        state['retry'].before(row);
        return true;
    }

    if (item.fail_count > 0 && item.status == 'running') {
        state['fail'].after(row);
        return true;
    }

    if (item.fail_count > 0) {
        state['fail'].before(row);
        return true;
    }

    if (item.status == 'running') {
        state['running'].before(row);
        return true;
    }

    if (item.status == 'pending') {
        state['pending'].before(row);
        return true;
    }

    state['other'].before(row);
    return true;
};
