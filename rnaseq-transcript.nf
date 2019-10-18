#! /usr/bin/env nextflow

// Copyright (C) 2017 IARC/WHO

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.


params.input_folder = '.'
params.input_file = null
params.output_folder= "."
params.mem  = 2
params.cpu  = 2
params.gtf  = null
params.prepDE_input = 'NO_FILE'
params.readlength = 75

params.twopass  = null

params.help = null

log.info ""
log.info "-----------------------------------------------------------------"
log.info "RNAseq-transcript-nf 2.0.0: gene- and transcript-level           "
log.info "expression quantification from RNA sequencing data with StringTie"
log.info "-----------------------------------------------------------------"
log.info "Copyright (C) IARC/WHO"
log.info "This program comes with ABSOLUTELY NO WARRANTY; for details see LICENSE"
log.info "This is free software, and you are welcome to redistribute it"
log.info "under certain conditions; see LICENSE for details."
log.info "--------------------------------------------------------"
log.info ""

if (params.help) {
    log.info "--------------------------------------------------------"
    log.info "  USAGE                                                 "
    log.info "--------------------------------------------------------"
    log.info ""
    log.info "nextflow run iarcbioinfo/rnaseq-transcript-nf [-with-docker] [OPTIONS]"
    log.info ""
    log.info "Mandatory arguments:"
    log.info '    --input_folder   FOLDER                  Folder containing RNA-seq BAM files whose expression to quantify.'
    log.info '    --gtf            FILE                    Annotation file.'
    log.info ""
    log.info "Optional arguments:"
	log.info '    --input_file     FILE                    File in TSV format containing ID and BAM names.'
    log.info '    --output_folder  STRING                  Output folder (default: results_alignment).'
	log.info '    --readlength     STRING                  Mean read length for count computation (default: 75).'
    log.info '    --cpu            INTEGER                 Number of cpu used by bwa mem and sambamba (default: 2).'
    log.info '    --mem            INTEGER                 Size of memory used for mapping (in GB) (default: 2).' 
    log.info ""
    log.info "Flags:"
    log.info "--twopass                                    Enable StringTie 2pass mode"
    log.info ""
    exit 0
} else {
/* Software information */
   log.info "input_folder   = ${params.input_folder}"
   log.info "input_file     = ${params.input_file}"
   log.info "cpu            = ${params.cpu}"
   log.info "mem            = ${params.mem}"
   log.info "readlength     = ${params.readlength}"
   log.info "output_folder  = ${params.output_folder}"
   log.info "gtf            = ${params.gtf}"
   log.info "help:            ${params.help}"
}

if(params.input_file){
	bam_files = Channel.fromPath("${params.input_file}")
     	   .splitCsv( header: true, sep: '\t', strip: true )
	       .map { row -> [ row.ID , row.readlength , file(row.bam) ] }
}else{
if (file(params.input_folder).listFiles().findAll { it.name ==~ /.*bam/ }.size() > 0){
       println "BAM files found, proceed with transcript quantification"; mode ='bam'
       bam_files = Channel.fromPath( params.input_folder+'/*.bam')
                          .map{ path -> [ path.name.replace(".bam",""), params.readlength, path ] }
			  .view()
}else{
       println "ERROR: input folder contains no fastq nor BAM files"; System.exit(1)
}
}

gtf = file(params.gtf)
bam_files.into { bam_files_41stpass; bam_files_42ndpass }

//input file for the prepDE python script
ch_prepDE_input = file(params.prepDE_input)

// 1st pass identifies new transcripts for each BAM file
process StringTie1stpass {
	cpus params.cpu
	memory params.mem+'G'
	tag { file_tag }

	input:
	set file_tag, val(readlength), file(bam) from bam_files_41stpass
	file gtf
	
	output:
	set file("${file_tag}"), val(readlength) into ST_out
	file "*.log" into stringtie_log
	publishDir params.output_folder, mode: 'copy', saveAs: {filename ->
            if (filename.indexOf(".log") > 0) "logs/$filename"
            else "sample_folders/$filename"
	}

	shell:
	if(params.twopass==null){
	  STopts="-e -B -A ${file_tag}_pass1_gene_abund.tab "
	}else{
	  STopts=" "
	}
    	'''
    	stringtie !{STopts} -o !{file_tag}_ST.gtf -p !{params.cpu} -G !{gtf} -l !{file_tag} !{bam}
		mkdir !{file_tag}
		mv *tab !{file_tag}/
		mv *_ST.gtf !{file_tag}/
		cp .command.log !{file_tag}.log
    	'''
}

ST_out4group = Channel.create()
ST_out_final = Channel.create()
ST_out_final4bg = Channel.create()
ST_out_final4print = Channel.create()
if(params.twopass){
// Merges the list of transcripts of each BAM file
process mergeGTF {
	cpus params.cpu
	memory params.mem+'G'
	tag { "merge" }

	input:
	file gtfs from ST_out.collect()
	file gtf

	output: 
	file("stringtie_merged.gtf") into merged_gtf
	file("gffcmp_merged*") into gffcmp_output
	publishDir "${params.output_folder}/gtf", mode: 'copy', pattern: '{gffcmp_merged*}' 

	shell:
	'''
	ls */*_ST.gtf > mergelist.txt
	stringtie --merge -p !{params.cpu} -G !{gtf} -o stringtie_merged.gtf mergelist.txt
	gffcompare -r !{gtf} -G -o gffcmp_merged stringtie_merged.gtf
	'''
}

// Quantifies transcripts identified in 1st pass in each sample
process StringTie2ndpass {
	cpus params.cpu
	memory params.mem+'G'
	tag { file_tag }

	input:
	set file_tag, val(readlength), file(bam) from bam_files_42ndpass
	file merged_gtf
	file gtf

	output: 
	set file("${file_tag}"), val(readlength) into ST_out2
	file "*.log" into stringtie_log_2pass
	publishDir params.output_folder, mode: 'copy', saveAs: {filename ->
        if (filename.indexOf(".log") > 0) "logs/$filename"
        else "sample_folders/$filename"
	}

	shell:
	file_tag=bam.baseName
	'''
	stringtie -e -B -p !{params.cpu} -G !{merged_gtf} -o !{file_tag}_ST_2pass.gtf -A !{file_tag}_gene_abund.tab !{bam}
	mkdir !{file_tag}
	mv *tab !{file_tag}/
	mv *_ST_2pass.gtf !{file_tag}/
	cp .command.log !{file_tag}.log
	'''
}
ST_out2.into( ST_out4group, ST_out_final4bg)
ST_out4group.groupTuple(by:1)
		    .into( ST_out_final, ST_out_final4print)
ST_out_final4print.subscribe{ println it}
}else{ 
	ST_out.into( ST_out4group, ST_out_final4bg)
	ST_out4group.groupTuple(by:1)
		    	.into( ST_out_final, ST_out_final4print)
	ST_out_final4print.subscribe{ println it}
}

process prepDE {
	cpus params.cpu
	memory params.mem +'G'
	tag { readlength }

	input:
	set file(ST_outs), val(readlength) from ST_out_final
	file samplenames from ch_prepDE_input

	output: 
	file("*count_matrix*.csv") into count_matrices
	publishDir "${params.output_folder}/expr_matrices", mode: 'copy'

	shell:
	input = samplenames.name != 'NO_FILE' ? "$samplenames" : '.'
	'''
	prepDE.py -i !{input} -l !{readlength} -g gene_count_matrix_l!{readlength}.csv -t transcript_count_matrix_l!{readlength}.csv
	'''
}

process ballgown_create {
	cpus params.cpu
	memory params.mem +'G'

	input:
	file ST_outs from ST_out_final4bg.collect()
	file samplenames from ch_prepDE_input

	output: 
	file("*_matrix.csv") into FPKM_matrices
	file("*.rda") into rdata
	publishDir "${params.output_folder}/expr_matrices", mode: 'copy'

	shell:
	input = samplenames.name != 'NO_FILE' ? "$samplenames" : '.'
	'''
	Rscript !{baseDir}/bin/create_matrices.R
	'''
}
