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
//        t2hui.fetch(uri, function(e) {
//            console.log(e);
//            var table = $('<table data="' + e.event_id + '"></table>');
//
//            var len = e.lines.length;
//            for (var i = 0; i < len; i++) {
//                var line = e.lines[i];
//                var cls = line.facet.replace(' ', '-') + ' ' + line.tag.replace(' ', '-');
//                var row = $('<tr class="' + cls + '"><td class="left"></td><th>' + line.tag + '</th><td class="right"></td></tr>');
//                console.log(i, cls, row);
//
//                if (line.content_json !== null) {
//                    var column = $('<td></td>');
//                    column.jsonView(line.content_json);
//                    row.append(column);
//                }
//                else {
//                    var content = line.content;
//                    row.append('<td><pre>' + content + '</pre></td>');
//                }
//
//                table.append(row);
//            }
//            render.append(table);
//        });

        root.body.append(details.root);
        root.body.append(render);
    });

    return root.root;
};

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
