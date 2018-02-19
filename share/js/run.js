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
