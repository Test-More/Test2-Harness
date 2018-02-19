t2hui.build_event = function(e, options) {
    var len = e.lines.length;
    var wrap = $('<div class="event"></div>');

    if (options === undefined) {
        options = {};
    }

    if (e.is_orphan || options.is_orphan) {
        wrap.addClass('orphan');
        wrap.hide();
    }
    if (len == 0) {
        wrap.addClass('no_lines');
        wrap.hide();
    }
    if (e.nested) {
        wrap.addClass('nested');
    }

    var table = $('<table></table>');
    wrap.append(table);

    var no_controls  = $('<td class="no_controls">&nbsp;</td>');
    var controls     = $('<td class="controls"></td>');

    var facet_toggle = $('<div class="facet_toggle etoggle">F</div>');
    controls.append(facet_toggle);

    var style = 'style="padding-left: ' + (2.2 + 2 * e.nested) + 'ch"';

    var first_row;
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
                var column = $('<td class="event_content" ' + style + '"></td>');
                column.jsonView(content, {collapsed: true});
                row.append(column);
            }
            else {
                row.append('<td class="event_content" ' + style +'><pre>' + content + '</pre></td>');
            }

            table.append(row);
        }
    }
    else {
        var row = $('<tr><td class="left"></td><th>HIDDEN</th><td class="right"></td></tr>');
        var column = $('<td class="event_content" ' + style + '><pre>' + e.event_id + '</pre></td>');

        row.prepend(controls);
        row.append(column);
        table.append(row);

        first_row = row;
    }

    if (e.is_parent) {
        var etoggle = $('<div class="etoggle subtest_control"></div>');
        first_row.find('pre').before(etoggle);

        etoggle.one('click', function() {
            var uri = base_uri + 'event/' + e.event_id + '/events';

            var kids = [];
            t2hui.fetch(uri, function(e2) {
                var sub_e = t2hui.build_event(e2, {is_orphan: e.is_orphan});
                sub_e.hide();
                wrap.after(sub_e);
                sub_e.slideDown();
                kids.push(sub_e);
            });

            etoggle.toggleClass('clicked');

            etoggle.click(function() {
                etoggle.toggleClass('clicked');

                for (i = 0; i < kids.length; i++) {
                    kids[i].find('div.subtest_control.clicked').click();
                    kids[i].slideToggle();
                }
            });
        });
    }

    facet_toggle.one('click', function() {
        var row = $('<tr class="facet_data"><td class="left"></td><th>FACETS</th><td class="right"></td></tr>');
        var column = $('<td class="event_content" ' + style + '></td>');
        column.jsonView(e.facets, {collapsed: true});
        row.prepend(no_controls);
        row.append(column);

        table.append(row);

        facet_toggle.toggleClass('clicked');

        row.slideDown();

        facet_toggle.click(function() {
            facet_toggle.toggleClass('clicked');
            row.slideToggle();
        });
    });

    return wrap;
};


/*
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
*/
