t2hui.build_event = function(e) {
    var len = e.lines.length;
    var wrap = $('<div class="event"></div>');

    if (e.is_orphan) {
        wrap.addClass('orphan');
        wrap.hide();
    }
    if (len == 0) {
        wrap.addClass('no_lines');
        wrap.hide();
    }

    var table = $('<table></table>');
    wrap.append(table);

    var no_controls  = $('<td class="no_controls">&nbsp;</td>');
    var controls     = $('<td class="controls"></td>');

    var facet_toggle = $('<div class="facet_toggle etoggle">F</div>');
    controls.append(facet_toggle);

    var rows = [];
    if (len) {
        for (var i = 0; i < len; i++) {
            var line = e.lines[i];
            var facet = line[0];
            var tag = line[1];
            var content = line[2];

            var cls = facet.replace(' ', '-') + ' ' + tag.replace(' ', '-');
            var row = $('<tr class="' + cls + '"><td class="left"></td><th>' + tag + '</th><td class="right"></td></tr>');
            if (i === 0) {
                row.prepend(controls);
                first_row = row;
            }
            else {
                row.prepend(no_controls.clone());
            }

            if (content !== null && typeof(content) === 'object') {
                var column = $('<td class="event_content"></td>');
                column.jsonView(content, {collapsed: true});
                row.append(column);
            }
            else {
                row.append('<td class="event_content"><pre>' + content + '</pre></td>');
            }

            rows.push(row);
            table.append(row);
        }
    }
    else {
        var row = $('<tr><td class="left"></td><th>HIDDEN</th><td class="right"></td></tr>');
        var column = $('<td class="event_content"><pre>' + e.event_id + '</pre></td>');

        row.prepend(controls);
        row.append(column);
        table.append(row);

        rows.push(row);
    }

    for(r = 0; r < rows.length; r++) {
        var row = rows[r];
        t2hui.apply_subtest_blocks(e, row, r, rows.slice(-1)[0]);
    }

    facet_toggle.one('click', function() {
        var row = $('<tr class="facet_data"><td class="left"></td><th>FACETS</th><td class="right"></td></tr>');
        var column = $('<td class="event_content"></td>');
        column.jsonView(e.facets, {collapsed: true});
        row.prepend(no_controls);
        row.append(column);

        var pad = 2 + (2 * e.nested);
        column.attr('style', 'padding-left: ' + pad + 'ch;');

        // Add after other rows from the initial event, before any added subtest events
        rows.slice(-1)[0].after(row);

        facet_toggle.toggleClass('clicked');

        row.slideDown();

        facet_toggle.click(function() {
            facet_toggle.toggleClass('clicked');
            row.slideToggle();
        });
    });

    return wrap;
};

t2hui.apply_subtest_blocks = function(e, row, r, where) {
    var subtest_block = $('<div class="subtest_block"></div>');
    var content = row.find('td.event_content').first();

    for(i = e.nested; i >= 0; i--) {
        var block = subtest_block.clone();

        if (r == 0 && e.is_parent && i === e.nested) {
            block.addClass('etoggle');
            block.text('');

            var children = [];
            block.one('click', function() {
                var me = $(this);
                var uri = base_uri + 'event/' + e.event_id + '/events';
                var last = where;

                t2hui.fetch(uri, function(e) {
                    var e_body = t2hui.build_event(e);
                    e_body.find('> table > tr').each(function() {
                        var tr = $(this);
                        last.after(tr);
                        last = tr;
                        children.push(tr);
                    });
                });

                me.addClass('clicked');

                me.click(function() {
                    me.toggleClass('clicked');

                    for (j = 0; j < children.length; j++) {
                        children[j].slideToggle();
                    }
                });
            });
        }

        content.prepend(block);
    }
}

