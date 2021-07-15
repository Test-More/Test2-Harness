t2hui.eventtable = {};

t2hui.eventtable.build_controls = function(run, job) {
    var filters = {
        seen: {},
        state: {},
        hide: {}
    };

    var controls = $('<div class="event_controls"></div>');
    var filter_dom = $('<ul class="event_filter"><li>Filter Tags:</li></ul>');
    controls.append(filter_dom);

    if (!(job.status == 'running' || job.status == 'pending')) {
        filters.hide = {
            'PASS': true,
            'PLAN': true,
            'HARNESS': true,
            'STDOUT': true,
        };
    }

    filters.dom = filter_dom;

    return {
        "filters":    filters,
        "dom":        controls,
        "filter_dom": filter_dom,
    };
};

t2hui.eventtable.build_table = function(run, job, controls) {
    var table;

    var columns = [
        { 'name': 'tools',   'label': 'tools',   'class': 'tools', 'builder': t2hui.eventtable.tool_builder },
        { 'name': 'tag',     'label': 'tag',     'class': 'tag' },
        {
            'name': 'message',
            'label': 'message',
            'class': 'message',
            'builder': function(item, dest, data) {
                t2hui.eventtable.message_builder(item, dest, data, table);
            },
        },
    ];

    table = new FieldTable({
        'class': 'job_table',
        'id': 'jobs_events',
        'updatable': false,

        'expand_item': t2hui.eventtable.expand_lines,

        'place_row': t2hui.eventtable.place_row,
        'modify_row_hook': function(row, item, table) { t2hui.eventtable.modify_row(row, item, table, controls) },

        'done': function() { $('.temp_orphan').detach() },

        'columns': columns,
    });

    return table;
};

t2hui.eventtable.expand_lines = function(item) {
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
            'id': item.event_id,
        });
        tools = false;
    });

    return out;
}

t2hui.eventtable.message_builder = function(item, dest, data, table) {
    t2hui.eventtable.message_inner_builder(item, dest, data);

    var indent = '' + ((item.item.nested + 1) * 2) + 'ch';
    dest.css('padding-left', indent);

    if (item.item.is_parent == false) { return }

    var events_uri = base_uri + 'event/' + item.item.event_id + '/events';

    var jumpto = window.location.hash.substr(1);
    var highlight = item.item.event_id === jumpto ? true : false;

    var expand = $('<div class="stoggle">+</div>');

    var load_subtest = function() {
        expand.text('~');
        expand.addClass('running');
        expand.addClass('expanded');
        expand.addClass('toggle_highlight');

        t2hui.fetch(
            events_uri,
            {
                done: function() {
                    var row = dest.parent();

                    expand.removeClass('running');
                    if (highlight) {
                        $('html, body').animate({
                              scrollTop: expand.offset().top - 120
                        });
                        row.addClass('highlight');
                    }

                    expand.click(function() {
                        highlight = !highlight;
                        console.log('click!', row, highlight);

                        if (highlight) {
                            row.addClass('highlight');
                            $('[data-parent-id="' + item.item.event_id + '"]').addClass('highlight');
                        }
                        else {
                            row.removeClass('highlight');
                            $('[data-parent-id="' + item.item.event_id + '"]').removeClass('highlight');
                        }
                    });
                }
            },
            function(e) {
                var params = {"data": {"parent-id": item.item.event_id}};
                if (highlight) {
                    params.class = "highlight";
                }
                table.render_item(e, null, params);
            }
        )
    }

    if (item.item.is_fail || highlight) {
        load_subtest();
    }
    else {
        expand = $('<div class="stoggle">+</div>');
        expand.one('click', load_subtest);
    }

    dest.prepend(expand);
}

t2hui.eventtable.place_row = function(row, item, table, state) {
    if (!item.item['loading_subtest']) {
        if (item.item.orphan) {
            row.addClass('temp_orphan');
            if (!state['orphan']) {
                state['orphan'] = row;
                row.addClass('first_orphan');
            }
            state['body'].append(row);
            return true;
        }
    }

    if (!item.item['parent_id']) {
        state['orphan'] = null;
        $('.temp_orphan').detach();
        state['body'].append(row);
        return true;
    }

    var pid = item.item['parent_id'];
    if (!state[pid]) {
        var got = table.table.find('tr[data-event-id="' + item.item.parent_id + '"]');
        state[pid] = got.last();
    }

    state[pid].after(row);
    state[pid] = row;

    return true;
}

t2hui.eventtable.message_inner_builder = function(item, dest, data) {
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

t2hui.eventtable.tool_builder = function(item, tools, data) {
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
                    var formatter = new JSONFormatter(event.facets, 2);
                    $('#modal_body').html(formatter.render());
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
                    var formatter = new JSONFormatter(event.orphan, 2);
                    $('#modal_body').html(formatter.render());
                },
            });
        });
    }
}

t2hui.eventtable.clean_tag = function(tag) {
    var clean = tag.replace(/[\W]+/g, "_");
    return clean;
}

t2hui.eventtable.modify_row = function(row, item, table, controls) {
    var tag = item.tag;
    var ctag = t2hui.eventtable.clean_tag(tag);

    row.addClass('event_line');
    row.addClass('facet_' + item.facet);
    row.addClass('tag_' + ctag);

    row.attr('data-event-id', item.item.event_id);

    if (!controls.filters.seen[tag]) {
        controls.filters.state[tag] = !controls.filters.hide[tag];
        controls.filters.seen[tag] = 1;

        var filter = $('<li class="filter">' + tag + '</li>');
        var added = false;
        controls.filters.dom.children('.filter').each(function() {
            if (added) { return false };

            var it = $(this);
            if (tag < it.text()) {
                added = true;
                it.before(filter);
                return false;
            }
        });
        if (!added) { controls.filters.dom.append(filter) }

        if (!controls.filters.state[tag]) {
            filter.addClass('off');
        }

        filter.click(function() {
            if (controls.filters.state[tag]) {
                controls.filters.state[tag] = false;
                $(this).addClass('off');
                table.table.find('tr.tag_' + ctag).addClass('hidden_row');
            }
            else {
                controls.filters.state[tag] = true;
                $(this).removeClass('off');
                table.table.find('tr.tag_' + ctag).removeClass('hidden_row');
            }
        })
    }

    if (!controls.filters.state[tag]) {
        row.addClass('hidden_row');
    }
}


