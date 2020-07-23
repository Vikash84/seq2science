if get_workflow() == "rna_seq":
    rule infer_strandedness:
        """
        use RSeqQC's infer_experiment.py to determine strandedness af a sample
        """
        input:
            bam=expand("{final_bam_dir}/{{assembly}}-{{sample}}.samtools-coordinate.bam", **config),
            bed=expand("{genome_dir}/{{assembly}}/{{assembly}}.annotation.bed", **config)
        output:
            temp(expand("{counts_dir}/{{assembly}}-{{sample}}.strandedness.txt", **config))
        log:
            expand("{log_dir}/counts_matrix/{{assembly}}-{{sample}}.strandedness.log", **config),
        params:
            config["min_mapping_quality"]
        conda:
            "../envs/gene_counts.yaml"
        shell:
            """
            infer_experiment.py -i {input.bam} -r {input.bed} -q {params} 1> {output} 2> {log}
            """


    def samples_to_infer(wildcards):
        """
        list all samples for which strandedness must be inferred
        """
        col = samples.replicate if "replicate" in samples else samples.index

        if config['ignore_strandedness'] or \
                ("strandedness" in samples and "nan" not in set(samples.strandedness)):
            files = []
        elif "strandedness" not in samples:
            files = [f"{{counts_dir}}/{samples[col == sample].assembly[0]}-{sample}.strandedness.txt" for sample in col]
        else:
            files = []
            for sample in set(col):
                if samples[col == sample].strandedness not in ["yes", "forward", "reverse", "no"]:
                    files.append(f"{{counts_dir}}/{samples[col == sample].assembly[0]}-{sample}.strandedness.txt")
        return expand(files, **config)


    checkpoint strandedness_report:
        """
        combine samples.tsv & infer_strandedness results (call strandedness if >60% of reads explains a direction)
        """
        input:
            samples_to_infer
        output:
            expand("{counts_dir}/inferred_strandedness.tsv", **config)
        run:
            import pandas as pd

            def get_strand(sample):
                report_file = [f for f in input if f.endswith(f"-{sample}.strandedness.txt")][0]
                with open(report_file) as report:
                    fail_val = fwd_val = 0
                    for line in report:
                        if line.startswith("Fraction of reads failed"):
                            fail_val = float(line.strip().split(": ")[1])
                        elif line.startswith(("""Fraction of reads explained by "1++""",
                                              """Fraction of reads explained by "++""")):
                            fwd_val = float(line.strip().split(": ")[1])

                if fwd_val > 0.6:
                    return "forward"
                elif 1 - (fwd_val + fail_val) > 0.6:
                    return "reverse"
                else:
                    return "no"

            strands = []
            method = []
            col = samples.replicate if "replicate" in samples else samples.index
            for sample in set(col):
                s = samples[col == sample].strandedness[0] if "strandedness" in samples else "nan"
                m = "user_specification"
                if config['ignore_strandedness']:
                    s = "no"
                    m = "ignored"
                elif s == "nan":
                    s = get_strand(sample)
                    m = "inferred"
                strands.append(s)
                method.append(m)

            strandedness = pd.DataFrame({"sample": list(col), "strandedness": strands, "determined_by": method}, dtype='str')
            strandedness.set_index('sample', inplace=True)
            strandedness.to_csv(output[0], sep="\t")


    def _strandedness_report(wildcards):
        return checkpoints.strandedness_report.get().output[0]

    def strandedness_to_quant(wildcards):
        """
        translate strandedness to quantifiers nomenclature
        """
        out = {
            "htseq": ["no", "yes", "reverse"],
            "featurecounts": ["0", "1", "2"]
        }

        strandedness = pd.read_csv(_strandedness_report(wildcards), sep='\t', dtype='str', index_col=0)
        s = strandedness[strandedness.index == wildcards.sample].strandedness[0]
        n = 1 if s in ["yes", "forward"] else (2 if s == "reverse" else 0)
        return out[config["quantifier"]][n]

    def strandedness_to_bambigwig(wildcards):
        """
        translate strandedness to command flag
        so the forward bam always corresponds to genes on the + strand
        """
        out = {
            ".fwd": ["--filterRNAstrand forward", "--filterRNAstrand reverse"],
            ".rev": ["--filterRNAstrand reverse", "--filterRNAstrand forward"],
            "": [""]
        }

        strandedness = pd.read_csv(_strandedness_report(wildcards), sep='\t', dtype='str', index_col=0)
        s = strandedness[strandedness.index == wildcards.sample].strandedness[0]
        n = 1 if s == "reverse" else 0
        return out[wildcards.strand][n]

    def strandedness_to_trackhub(sample):
        """
        translate strandedness to the name and number of bigwigs to include in the trackhub
        """
        strandedness = pd.read_csv(_strandedness_report(wildcards=None), sep='\t', dtype='str', index_col=0)
        s = strandedness[strandedness.index == sample].strandedness[0]
        return [".fwd", ".rev"] if s in ["yes", "forward", "reverse"] else [""]

else:
    def _strandedness_report(wildcards):
        """dummy function"""
        return []

    def strandedness_to_bambigwig(wildcards):
        """dummy function"""
        return ""

    def strandedness_to_trackhub(sample):
        """dummy function"""
        return [""]