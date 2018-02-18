$(function() {
    $("div.run").each(function() {
        var it = $(this);
        var run_id = it.attr('data-run-id');
        var uri = base_uri + 'run/' + run_id + '/jobs';

        var log = it.children('div.log').first();
        var failed = it.children('div.failed').first();
        var passed = it.children('div.passed').first();

        t2hui.fetch(uri, function(job) {
            job_dom = t2hui.build_job(job);

            if (job.name === '0') {
                log.append(job_dom);
            }
            else if (job.fail) {
                failed.append(job_dom);
            }
            else {
                passed.append(job_dom);
            }
        });
    });
});

t2hui.build_job = function(job) {
    var root;

    root = t2hui.build_expander(job.short_file, 'job', function() {
        var details;
        details = t2hui.build_expander('Details', 'details', function() {
            var jsonv = $('<div class="job json-view"></div>');
            jsonv.jsonView(job);
            details.body.append(jsonv);
        });

        var render = $('<div class="job-render"></div>');

        var uri = base_uri + 'job/' + job.job_id + '/events';
        t2hui.fetch(uri, function(e) {
            var wrap = $('<div class="event"></div>');
            var table = $('<table data="' + e.event_id + '"></table>');
            wrap.append(table);

            var no_controls  = $('<td class="no_controls">&nbsp;</td>');
            var controls     = $('<td class="controls"></td>');
            var facet_toggle = $('<input type="checkbox" unchecked>');
            controls.append(facet_toggle);

            var len = e.lines.length;
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
                    }
                    else {
                        row.prepend(no_controls.clone());
                    }

                    if (content !== null && typeof(content) === 'object') {
                        var column = $('<td class="event_content"></td>');
                        column.jsonView(content);
                        row.append(column);
                    }
                    else {
                        row.append('<td class="event_content"><pre>' + content + '</pre></td>');
                    }

                    table.append(row);
                }
            }
            else {
                var row = $('<tr class="no_lines"><td class="left"></td><th>HIDDEN</th><td class="right"></td></tr>');
                var column = $('<td class="event_content"><pre>' + e.event_id + '</pre></td>');

                row.prepend(controls);
                row.append(column);
                table.append(row);
            }

            facet_toggle.one('click', function() {
                var row = $('<tr class="facet_data" style="display: none;"><td class="left"></td><th>FACETS</th><td class="right"></td></tr>');
                var column = $('<td class="event_content"></td>');
                column.jsonView(e.facets);
                row.prepend(no_controls);
                row.append(column);
                table.append(row);

                row.slideDown();

                facet_toggle.click(function() {
                    row.slideToggle();
                });
            });

            render.append(wrap);
        });

        root.body.append(details.root);
        root.body.append(render);
    });

    return root.root;
};

//                var facets;
//                facets = t2hui.build_expander('Facets', 'facets', function() {
//                    var div = $('<div class="json-view"></div>');
//                    div.jsonView(e);
//                    facets.body.append(div);
//                });
//
//                column.append(facets.root);

//
//
//
//CREATE TABLE jobs (
//    job_id          UUID        NOT NULL PRIMARY KEY,
//    job_ord         BIGINT      NOT NULL,
//    run_id          UUID        NOT NULL REFERENCES runs(run_id),
//
//    stream_ord      SERIAL      NOT NULL,
//
//    parameters      JSONB       DEFAULT NULL,
//
//    -- Summaries
//    name            TEXT        NOT NULL,
//    file            TEXT        DEFAULT NULL,
//    fail            BOOL        DEFAULT NULL,
//    exit            INT         DEFAULT NULL,
//    launch          TIMESTAMP   DEFAULT NULL,
//    start           TIMESTAMP   DEFAULT NULL,
//    ended           TIMESTAMP   DEFAULT NULL
//);
//
