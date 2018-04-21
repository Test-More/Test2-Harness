$(function() {
    $("div.run").each(function() {
        var me = $(this);
        t2hui.build_run(me.attr('data-run-id'), me);
    });
});

t2hui.build_run = function(run_id, root, list) {
    if (root === null || root === undefined) {
        root = $('<div class="run" data-run-id="' + run_id + '"></div>');
    }

    var run_uri = base_uri + 'run/' + run_id;
    var jobs_uri = run_uri + '/jobs';

    $.ajax(run_uri, {
        'data': { 'content-type': 'application/json' },
        'success': function(item) {
            var dash = t2hui.build_dashboard_runs([item]);
            root.prepend($('<h3>Run: ' + run_id + '</h3>'), dash, $('<hr />'));

        },
    });

    var jobs = $('<div class="job_list grid"></div>');
    jobs.append(t2hui.build_run_job_header());
    // [expand], [params], [link]

    var pos  = $('<div style="display: none;"></div>');
    var log = pos.clone();
    var error = pos.clone();
    var other = pos.clone();
    jobs.append(log, error, other);

    root.append('<h3>Jobs:</h3>', jobs);

    var inject = function(job) {
        if (job === null || job === undefined) {
            job = this;
        }

        job_dom = t2hui.build_run_job(job);

        if (!job.file) {
            log.before(job_dom);
        }
        else if (job.fail) {
            error.before(job_dom);
        }
        else {
            other.before(job_dom);
        }
    }

    if (list === null || list === undefined) {
        t2hui.fetch(jobs_uri, {}, inject);
    }
    else {
        $(list).each(inject);
    };

    return root;
};

t2hui.build_run_job_header = function(job) {
    var me = [
        $('<div class="col1 head tools">Tools</div>'),
        $('<div class="col2 head pass count">P</div>'),
        $('<div class="col3 head fail count">F</div>'),
        $('<div class="col4 head job_name">File/Job Name</div>'),
        $('<div class="col5 head exit count">Exit</div>'),
    ];

    return me;
}

t2hui.build_run_job = function(job) {
    var tools = $('<div class="col1 tools"></div>');

    var params = $('<div class="tool etoggle" title="See Job Parameters"><i class="far fa-list-alt"></i></div>');
    tools.append(params);
    params.click(function() {
        $('#modal_body').jsonView(job.parameters, {collapsed: true});
        $('#free_modal').slideDown();
    });

    var link = base_uri + 'job/' + job.job_id;
    var go = $('<a class="tool etoggle" title="Open Job" href="' + link + '"><i class="fas fa-external-link-alt"></i></a>');
    tools.append(go);

    var me = [
        tools[0],
        $('<div class="col2 pass count">' + (job.pass_count || '0') + '</div>')[0],
        $('<div class="col3 fail count">' + (job.fail_count || '0') + '</div>')[0],
        $('<div class="col4 job_name">' + (job.short_file || job.name) + '</div>')[0],
        $('<div class="col5 exit count">' + (job.exit != null ? job.exit : 'N/A') + '</div>')[0],
    ];

    var $me = $(me);

    if (job.file) {
        if (job.fail) {
            $me.addClass('error_set');
        }
        else {
            $me.addClass('success_set');
        }
    }

    return $me;
};
