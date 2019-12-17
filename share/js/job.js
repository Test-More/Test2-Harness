$(function() {
    $("div.job").each(function() {
        var root = $(this);
        var job_key = root.attr('data-job-key');

        var job_uri = base_uri + 'job/' + job_key;
        $.ajax(job_uri, {
            'data': { 'content-type': 'application/json' },
            'success': function(item) {
                var dash = t2hui.run.build_table([item]);
                root.prepend($('<h3>Job: ' + (item.short_file || item.name) + '</h3>'), dash, $('<hr />'));
            },
        });

        var controls = $('<div class="event_controls"></div>');
        var filters = $('<ul class="event_filter"><li>Filter Tags:</li></ul>');
        controls.append(filters);
        root.append(controls);
        t2hui.job.filters.dom = filters;

        var events_uri = job_uri + '/events';
        var table = t2hui.job.build_table(events_uri);
        root.append(table);
    });
});

t2hui.job = {
    'filters': {
        seen: {},
        state: {},
        hide: {
            'PASS': true,
            'PLAN': true,
            'HARNESS': true,
        }
    },
};

t2hui.job.build_table = function(uri) {
    var columns = [
        { 'name': 'tools',   'label': 'tools',   'class': 'tools', 'builder': t2hui.job.tool_builder },
        { 'name': 'tag',     'label': 'tag',     'class': 'tag' },
        { 'name': 'message', 'label': 'message', 'class': 'message', 'builder': t2hui.job.message_builder },
    ];

    var table = new FieldTable({
        'class': 'job_table',
        'id': 'jobs_events',
        'fetch': uri,
        'sortable': false,
        'expand_item': t2hui.job.expand_item,

        'place_row': t2hui.job.place_row,
        'modify_row_hook': t2hui.job.modify_row,

        'columns': columns,
    });

    var dom = table.render();

    t2hui.job.table = table;

    return dom;
};

t2hui.job.expand_item = function(item) {
    var out = [];

    var tools = true;
    var count = 0;
    item.lines.forEach(function(line) {
        out.push({
            'tools': tools ? item.lines.length : false,
            'tag': line[1],
            'message': line[2],
            'table': line[3],
            'facet': line[0],
            'item': item,
            'set_ord': count++,
            'set_total': item.lines.length,
        });
        tools = false;
    });

    return out;
}

t2hui.job.message_builder = function(item, dest, data) {
    t2hui.job.message_inner_builder(item, dest, data);

    var indent = '' + ((item.item.nested + 1) * 2) + 'ch';
    dest.css('padding-left', indent);

    if (!item.item.is_parent) { return }

    var expand = $('<div class="stoggle">+</div>');
    dest.prepend(expand);

    expand.one('click', function() {
        expand.text('~');
        expand.addClass('running');
        expand.addClass('expanded');
        var events_uri = base_uri + 'event/' + item.item.event_id + '/events';

        t2hui.fetch(
            events_uri,
            {done: function() { expand.removeClass('running') } },
            t2hui.job.table.render_item,
        )
    });
}

t2hui.job.place_row = function(row, item, table, state) {
    if (!item.item.parent_id) { return false }

    var pid = item.item.parent_id;
    if (!state[pid]) {
        state[pid] = table.find('tr[data-event-id="' + item.item.parent_id + '"]').last();
    }

    state[pid].after(row);
    state[pid] = row;

    return true;
}

t2hui.job.message_inner_builder = function(item, dest, data) {
    if (!item.table) {
        var pre = $('<pre class="testout"></pre>');
        pre.text(item.message);
        dest.append(pre);
        return;
    }

    var data = item.table;

    var table = $('<table class="testtable"></table>');
    var header = $('<tr></tr>');
    table.append(header);

    for (var x = 0; x < data.header.length; x++) {
        var th = $('<th class="header"></th>');
        th.text(data.header[x]);
        header.append(th);
    }

    for (var x = 0; x < data.rows.length; x++) {
        var row_data = data.rows[x];
        var row = $('<tr></tr>');
        table.append(row);

        for (var y = 0; y < row_data.length; y++) {
            var col = $('<td class="' + data.header[y].toLowerCase() + '"></td>');
            col.text(row_data[y]);
            row.append(col);
        }
    }

    dest.append(table);
}

t2hui.job.tool_builder = function(item, tools, data) {
    if (!item.tools) { tools.hide(); return }

    tools.attr('rowspan', item.tools);

    if (item.item.facets) {
        var efacet = $('<div class="tool etoggle" title="See Raw Facet Data"><img src="/img/data.png" /></div>');
        tools.append(efacet);
        efacet.click(function() {
            $('#modal_body').empty();
            $('#modal_body').text("loading...");
            $('#free_modal').slideDown();

            var uri = base_uri + 'event/' + item.item.event_id;

            $.ajax(uri, {
                'data': { 'content-type': 'application/json' },
                'success': function(event) {
                    $('#modal_body').empty();
                    $('#modal_body').jsonView(event.facets, {collapsed: true});
                },
            });
        });
    }

    if (item.item.orphan) {
        var eorphan = $('<div class="tool etoggle" title="See Orphan Facet Data"><img src="/img/orphan.png" /></div>');
        tools.append(eorphan);
        eorphan.click(function() {
            $('#modal_body').empty();
            $('#modal_body').text("loading...");
            $('#free_modal').slideDown();

            var uri = base_uri + 'event/' + item.item.event_id;

            $.ajax(uri, {
                'data': { 'content-type': 'application/json' },
                'success': function(event) {
                    $('#modal_body').empty();
                    $('#modal_body').jsonView(event.orphan, {collapsed: true});
                },
            });
        });
    }
}

t2hui.job.clean_tag = function(tag) {
    var clean = tag.replace(' ', '_');
    return clean;
}

t2hui.job.modify_row = function(row, item) {
    var tag = item.tag;
    var ctag = t2hui.job.clean_tag(tag);

    row.addClass('facet_' + item.facet);
    row.addClass('tag_' + ctag);

    row.attr('data-event-id', item.item.event_id);

    if (!t2hui.job.filters.seen[tag]) {
        t2hui.job.filters.state[tag] = !t2hui.job.filters.hide[tag];
        t2hui.job.filters.seen[tag] = 1;

        var filter = $('<li class="filter">' + tag + '</li>');
        var added = false;
        t2hui.job.filters.dom.children('.filter').each(function() {
            if (added) { return false };

            var it = $(this);
            if (tag < it.text()) {
                added = true;
                it.before(filter);
                return false;
            }
        });
        if (!added) { t2hui.job.filters.dom.append(filter) }

        if (!t2hui.job.filters.state[tag]) {
            filter.addClass('off');
        }

        filter.click(function() {
            if (t2hui.job.filters.state[tag]) {
                t2hui.job.filters.state[tag] = false;
                $(this).addClass('off');
                t2hui.job.table.table.find('tr.tag_' + ctag).addClass('hidden_row');
            }
            else {
                t2hui.job.filters.state[tag] = true;
                $(this).removeClass('off');
                t2hui.job.table.table.find('tr.tag_' + ctag).removeClass('hidden_row');
            }
        })
    }

    if (!t2hui.job.filters.state[tag]) {
        row.addClass('hidden_row');
    }
}


